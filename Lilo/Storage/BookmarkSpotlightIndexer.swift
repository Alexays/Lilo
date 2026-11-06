@preconcurrency @unsafe import CoreSpotlight
import CryptoKit
import Foundation
import GRDB
import os

/// Mirrors a profile's bookmarks into Spotlight. Every write to the bookmark table,
/// whichever path made it (sidebar, extensions, import), updates the profile's Spotlight items in one batch,
/// unless their URLs and titles hash to what the domain last indexed that week.
final class BookmarkSpotlightIndexer: Sendable {
    /// Bookmark titles by URL as last sent to Spotlight in a week; nil until known or after a failed call.
    private typealias Indexed = (week: Int, titles: [String: String])

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
        let indexed = OSAllocatedUnfairLock<Indexed?>(initialState: nil)
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
                    try dbPool.read { db in Self.reindex(db, domain: domain, indexed: indexed) }
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
        unsafe UserDefaults.lilo.removeObject(forKey: hashKey(for: domain))
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }

    /// Rebuilds the domain on the first change of a process or a week; otherwise sends Spotlight only
    /// the bookmarks added, retitled or removed since the last call.
    private static func reindex(_ db: Database, domain: String, indexed: OSAllocatedUnfairLock<Indexed?>) {
        guard let records = try? ChromeBookmarkRecord.filter(Column("url") != nil)
            .order(Column("url"), Column("title")).fetchAll(db) else { return }
        // The week number joins the hash, so an index macOS wiped is rebuilt within a week: the
        // reindex requests of CSSearchableIndexDelegate go to an index app extension, which Lilo lacks.
        let week = Int(Date().timeIntervalSince1970 / (7 * 24 * 3600))
        var digestInput = "\(week)\n"
        for record in records {
            digestInput += record.url ?? ""
            digestInput += "\0"
            digestInput += record.title
            digestInput += "\n"
        }
        let hash = Data(SHA256.hash(data: Data(digestInput.utf8)))
        let key = hashKey(for: domain)
        let previous = indexed.withLock { $0 }
        let unchanged = unsafe UserDefaults.lilo.data(forKey: key) == hash
        guard !unchanged || previous == nil else {
            PerfSignposts.energy.emitEvent("spotlightSkipped")
            return
        }
        var titles: [String: String] = [:]
        for record in records {
            guard let string = record.url, let url = URL(string: string), url.scheme == "http" || url.scheme == "https" else { continue }
            titles[string] = record.title
        }
        indexed.withLock { [titles] in $0 = (week, titles) }
        guard !unchanged else {
            PerfSignposts.energy.emitEvent("spotlightSkipped")
            return
        }
        let signpost = PerfSignposts.energy.beginInterval("spotlightReindex")
        let rebuilds = previous?.week != week
        let changed = rebuilds ? titles : titles.filter { previous?.titles[$0.key] != $0.value }
        let items = changed.compactMap { string, title -> CSSearchableItem? in
            guard let url = URL(string: string) else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: .url)
            attributes.title = title.isEmpty ? url.host() : title
            attributes.url = url
            attributes.contentDescription = string
            return CSSearchableItem(uniqueIdentifier: string, domainIdentifier: domain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        let indexChanged: @Sendable (Error?) -> Void = { deleteError in
            // A failed call forgets the hash and the indexed titles, so the next launch or write rebuilds.
            let record: @Sendable (Error?) -> Void = { indexError in
                PerfSignposts.energy.endInterval("spotlightReindex", signpost, "\(items.count) items")
                if deleteError == nil, indexError == nil {
                    if indexed.withLock({ $0 != nil }) { unsafe UserDefaults.lilo.set(hash, forKey: key) }
                } else {
                    indexed.withLock { $0 = nil }
                    unsafe UserDefaults.lilo.removeObject(forKey: key)
                }
            }
            if items.isEmpty { record(nil) } else { index.indexSearchableItems(items, completionHandler: record) }
        }
        if rebuilds {
            index.deleteSearchableItems(withDomainIdentifiers: [domain], completionHandler: indexChanged)
        } else {
            let removed = previous?.titles.keys.filter { titles[$0] == nil } ?? []
            if removed.isEmpty { indexChanged(nil) } else { index.deleteSearchableItems(withIdentifiers: removed, completionHandler: indexChanged) }
        }
    }
}
