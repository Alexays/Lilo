import Foundation
import os

private let historyPageLogger = Logger(liloCategory: "history")

extension Notification.Name {
    /// A profile's history changed (visits written or removed); the object is the profile's UUID.
    static let historyChanged = Notification.Name("LiloHistoryChanged")
}

/// Serves the History page: day rows in batches, the sidebar summary, and deletions.
@MainActor
final class HistoryPageBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = [
        "loadHistoryPage",
        "loadHistorySidebar",
        "deleteHistoryRows",
        "deleteHistorySite",
        "closeHistoryPage"
    ]

    /// Rows a batch reaches before it stops at a day's end.
    private static let batchRows = 200

    private let profileContextProvider: () -> ProfileContext?
    private weak var bridgeRouter: BridgeRouter?
    /// Changes reach the page only while it is open: nothing is read for a closed page.
    private var pageOpen = false
    /// Favicons the page already holds, so each one crosses the bridge once per window.
    private var sentFaviconHosts: Set<String> = []
    nonisolated(unsafe) private var changeObserver: Any?

    init(profileContextProvider: @escaping () -> ProfileContext?, bridgeRouter: BridgeRouter) {
        self.profileContextProvider = profileContextProvider
        self.bridgeRouter = bridgeRouter
        changeObserver = NotificationCenter.default.addObserver(forName: .historyChanged, object: nil, queue: .main) { [weak self] note in
            let profileId = note.object as? UUID
            MainActor.assumeIsolated {
                guard let self, self.pageOpen, profileId == self.profileContextProvider()?.profileId else { return }
                self.bridgeRouter?.send(event: "historyChanged")
            }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let context = profileContextProvider() else {
            if message.action == "loadHistoryPage" { sendEmptyPage(for: message) }
            return nil
        }
        let store = context.history
        switch message.action {
        case "loadHistoryPage":
            pageOpen = true
            let filter = HistoryStore.Filter(
                query: message.string("query", default: ""),
                period: message.string("period").flatMap(HistoryStore.Period.init(rawValue:)) ?? .all,
                host: message.string("host"),
                openedFrom: message.string("openedFrom")
            )
            let before = message.double("before").map { Date(timeIntervalSince1970: $0 / 1000) }
            let favicons = context.favicons
            let sentHosts = sentFaviconHosts
            let minimumRows = Self.batchRows
            let loaded = await Task.detached(priority: .userInitiated) {
                () -> ((rows: [HistoryStore.DayRow], nextBefore: Date?), [String: String])? in
                do {
                    let page = try store.dayRows(filter: filter, before: before, minimumRows: minimumRows)
                    // Favicons are keyed by the page's own host; the chrome looks them up by site.
                    var siteByHost: [String: String] = [:]
                    for row in page.rows {
                        guard let host = URL(string: row.url)?.host?.lowercased(), !sentHosts.contains(row.host) else { continue }
                        siteByHost[host] = row.host
                    }
                    let entries = try favicons.entries(forHosts: Set(siteByHost.keys))
                    return (page, Dictionary(entries.compactMap { entry in siteByHost[entry.host].map { ($0, entry.dataURL) } },
                                             uniquingKeysWith: { first, _ in first }))
                } catch {
                    historyPageLogger.error("history page read failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
            // A failed read still answers, or the page would wait on it and never load more.
            guard let (page, icons) = loaded else {
                sendEmptyPage(for: message)
                break
            }
            sentFaviconHosts.formUnion(icons.keys)
            var data: [String: Any] = [
                "requestId": message.int("requestId") ?? 0,
                "rows": page.rows.map { row -> [String: Any] in
                    [
                        "pageId": row.pageId.uuidString,
                        "url": row.url,
                        "title": row.title,
                        "host": row.host,
                        "lastVisitAt": row.lastVisitAt.timeIntervalSince1970 * 1000,
                        "visits": row.visits,
                        "dayStart": row.dayStart.timeIntervalSince1970 * 1000
                    ]
                },
                "favicons": icons
            ]
            if let next = page.nextBefore { data["nextBefore"] = next.timeIntervalSince1970 * 1000 }
            bridgeRouter?.send(event: "historyPage", data: data)

        case "loadHistorySidebar":
            guard let summary = await Task.detached(priority: .userInitiated, operation: { () -> HistoryStore.SidebarSummary? in
                do { return try store.sidebarSummary() } catch {
                    historyPageLogger.error("history sidebar read failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }).value else { break }
            bridgeRouter?.send(event: "historySidebar", data: [
                "today": summary.today,
                "yesterday": summary.yesterday,
                "last7Days": summary.last7Days,
                "sites": summary.sites.map { ["host": $0.host, "visits": $0.visits] },
                "terminals": summary.terminals.map { ["openedFrom": $0.openedFrom, "visits": $0.visits] }
            ])

        case "deleteHistoryRows":
            let rows = (message.payload["rows"] as? [[String: Any]] ?? []).compactMap { row -> (pageId: UUID, dayStart: Date)? in
                guard let id = (row["pageId"] as? String).flatMap(UUID.init(uuidString:)),
                      let dayStart = (row["dayStart"] as? NSNumber)?.doubleValue else { return nil }
                return (id, Date(timeIntervalSince1970: dayStart / 1000))
            }
            let openedFrom = message.string("openedFrom")
            await deleting { try store.deleteDayRows(rows, openedFrom: openedFrom) }

        case "deleteHistorySite":
            guard let host = message.string("host"), !host.isEmpty else { break }
            await deleting { try store.deleteSite(host) }

        case "closeHistoryPage":
            pageOpen = false

        default:
            break
        }
        return nil
    }

    private func sendEmptyPage(for message: BridgeMessage) {
        bridgeRouter?.send(event: "historyPage", data: ["requestId": message.int("requestId") ?? 0, "rows": [], "favicons": [:]])
    }

    /// Runs a deletion off the main actor, then has the page reload: a partial deletion removes no page, so the store reports nothing.
    private func deleting(_ delete: @escaping @Sendable () throws -> [String]) async {
        await Task.detached(priority: .userInitiated) {
            do { _ = try delete() } catch {
                historyPageLogger.error("history delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
        bridgeRouter?.send(event: "historyChanged")
    }
}
