@preconcurrency import CoreSpotlight
import CryptoKit
import Foundation
import GRDB
import os

/// Mirrors a profile's bookmarks into Spotlight. Every write to the bookmark table,
/// whichever path made it (sidebar, extensions, import), re-indexes the profile's bookmarks in one batch,
/// unless their URLs and titles hash to what the domain last indexed that week.
final class BookmarkSpotlightIndexer: Sendable {
    private let observation: AnyDatabaseCancellable?
    private static let queue = DispatchQueue(label: "Lilo.BookmarkSpotlightIndexer", qos: .utility)
    private static let logger = Logger(liloCategory: "storage")

    static func domain(for profileId: UUID) -> String { "bookmarks.\(profileId.uuidString)" }
    private static func hashKey(for domain: String) -> String { "BookmarkSpotlightIndexer.hash.\(domain)" }

    init(dbPool: DatabasePool, profileId: UUID) {
        // Test runs build throwaway profiles that must never reach the user's Spotlight.
        guard !ProcessInfo.isRunningUnderXCTest else {
            observation = nil
            return
        }
        let domain = Self.domain(for: profileId)
        let scheduled = OSAllocatedUnfairLock(initialState: false)
        // A burst of commits (an import, an extension sync) coalesces into one reindex, read off the writer queue.
        let schedule: @Sendable () -> Void = {
            let alreadyScheduled = scheduled.withLock { pending in
                defer { pending = true }
                return pending
            }
            guard !alreadyScheduled else { return }
            Self.queue.asyncAfter(deadline: .now() + 1) {
                scheduled.withLock { $0 = false }
                loggingPersistenceError("bookmarkSpotlight.reindex") {
                    try dbPool.read { db in Self.reindex(db, domain: domain) }
                }
            }
        }
        schedule()
        observation = DatabaseRegionObservation(tracking: ChromeBookmarkRecord.all())
            .start(in: dbPool, onError: { error in
                Self.logger.error("bookmark observation failed: \(error.localizedDescription, privacy: .public)")
            }, onChange: { _ in schedule() })
    }

    static func removeAll(profileId: UUID) {
        let domain = Self.domain(for: profileId)
        UserDefaults.lilo.removeObject(forKey: hashKey(for: domain))
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }

    private static func reindex(_ db: Database, domain: String) {
        guard let records = try? ChromeBookmarkRecord.filter(Column("url") != nil)
            .order(Column("url"), Column("title")).fetchAll(db) else { return }
        // The week number joins the hash, so an index macOS wiped is rebuilt within a week: the
        // reindex requests of CSSearchableIndexDelegate go to an index app extension, which Lilo lacks.
        var digestInput = "\(Int(Date().timeIntervalSince1970 / (7 * 24 * 3600)))\n"
        for record in records {
            digestInput += record.url ?? ""
            digestInput += "\0"
            digestInput += record.title
            digestInput += "\n"
        }
        let hash = Data(SHA256.hash(data: Data(digestInput.utf8)))
        let key = hashKey(for: domain)
        guard UserDefaults.lilo.data(forKey: key) != hash else {
            PerfSignposts.energy.emitEvent("spotlightSkipped")
            return
        }
        let signpost = PerfSignposts.energy.beginInterval("spotlightReindex")
        let items = records.compactMap { record -> CSSearchableItem? in
            guard let string = record.url, let url = URL(string: string),
                  url.scheme == "http" || url.scheme == "https" else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: .url)
            attributes.title = record.title.isEmpty ? url.host() : record.title
            attributes.url = url
            attributes.contentDescription = string
            return CSSearchableItem(uniqueIdentifier: string, domainIdentifier: domain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { deleteError in
            // A failed call leaves the hash unrecorded, so the next launch or write retries.
            let record: @Sendable (Error?) -> Void = { indexError in
                PerfSignposts.energy.endInterval("spotlightReindex", signpost, "\(items.count) items")
                if deleteError == nil, indexError == nil { UserDefaults.lilo.set(hash, forKey: key) }
            }
            if items.isEmpty { record(nil) } else { index.indexSearchableItems(items, completionHandler: record) }
        }
    }
}
