import Foundation
import WebKit

/// Window state a `SessionsBridgeHandler` operates on. Supplied lazily by the owning window
/// (`MainWindowController`) so the handler - created inside the per-window gap router before any
/// window state exists - can read the recently-closed-tab stack and reopen from it.
@MainActor
struct SessionsContext {
    /// The closed tabs the window's extensions may see, pages outside private spaces, newest first.
    let recentlyClosed: [RecentlyClosedStack.Entry]
    /// Reopens the closed tab at this index of `recentlyClosed`.
    let restore: (Int) -> Void
}

/// `chrome.sessions` over the window's recently-closed-tab stack. A session id is the stack entry's id, which stays while the
/// entry does; there is no cross-device sync, so `getDevices` returns an empty list in JS.
@MainActor
final class SessionsBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "sessions.getRecentlyClosed",
        "sessions.restore"
    ]

    private static let defaultMaxResults = 25

    /// A window showing the calling extension's profile, from its registry.
    private let contextProvider: (ProfileExtensionRegistry) -> SessionsContext?

    init(
        contextProvider: @escaping (ProfileExtensionRegistry) -> SessionsContext?
    ) {
        self.contextProvider = contextProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let context = contextProvider(call.registry) else { return BridgeError("No active window for sessions") }

        switch call.action {
        case "sessions.getRecentlyClosed":
            let maxResults = call.int("maxResults") ?? Self.defaultMaxResults
            return context.recentlyClosed.prefix(max(0, maxResults)).enumerated().compactMap { index, entry in
                Self.session(entry, index: index)
            }

        case "sessions.restore":
            let entries = context.recentlyClosed
            let index = if let id = call.string("sessionId") {
                Int(id).flatMap { id in entries.firstIndex { $0.id == id } }
            } else {
                entries.indices.first
            }
            guard let index, let session = Self.session(entries[index], index: index) else {
                return BridgeError("No recently closed session to restore")
            }
            context.restore(index)
            return session

        default:
            return nil
        }
    }

    /// Fires `sessions.onChanged` to the listening extensions of each profile a closed page joined or left the stack of.
    static func recentlyClosedChanged(from old: RecentlyClosedStack, to new: RecentlyClosedStack, in context: BrowserContext) {
        let oldEntries = old.recentEntries, newEntries = new.recentEntries
        let oldIds = Set(oldEntries.map(\.id)), newIds = Set(newEntries.map(\.id))
        guard oldIds != newIds else { return }
        var notified: Set<UUID> = []
        for entry in oldEntries + newEntries where oldIds.contains(entry.id) != newIds.contains(entry.id) {
            guard case .page = entry.content, let space = context.spaceManager?.space(with: entry.spaceId), !space.isPrivate,
                  notified.insert(space.profileId).inserted,
                  let registry = context.profileContexts.existingContext(for: space.profileId)?.extensions else { continue }
            registry.emitGapEvent("sessions", "onChanged", args: [], requiredPermission: "sessions")
        }
    }

    /// Chrome's `Session` for a closed page, nil for any other entry.
    private static func session(_ entry: RecentlyClosedStack.Entry, index: Int) -> [String: Any]? {
        guard case .page(let url) = entry.content else { return nil }
        return [
            "lastModified": Date().timeIntervalSince1970,
            "tab": [
                "sessionId": String(entry.id),
                "url": url.absoluteString,
                "title": url.host ?? url.absoluteString,
                "index": index,
                "windowId": -1,
                "pinned": false,
                "active": false,
                "highlighted": false,
                "selected": false,
                "incognito": false
            ] as [String: Any]
        ]
    }
}
