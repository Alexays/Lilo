import Foundation
import WebKit

/// Window state a `SessionsBridgeHandler` operates on. Supplied lazily by the owning window
/// (`MainWindowController`) so the handler - created inside the per-window gap router before any
/// window state exists - can read the recently-closed-tab stack and reopen from it.
@MainActor
struct SessionsContext {
    /// Recently closed tab URLs outside private spaces, newest first.
    let recentlyClosedURLs: [URL]
    /// Reopens the closed tab at this index of `recentlyClosedURLs`.
    let restore: (Int) -> Void
}

/// `chrome.sessions` over the window's recently-closed-tab stack. A session id is the tab's index in `getRecentlyClosed`'s
/// newest-first list; there is no cross-device sync, so `getDevices` returns an empty list in JS.
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
            let urls = context.recentlyClosedURLs.prefix(max(0, maxResults))
            return urls.enumerated().map { index, url in Self.session(index: index, url: url) }

        case "sessions.restore":
            let index = call.string("sessionId").map { Int($0) ?? -1 } ?? 0
            guard context.recentlyClosedURLs.indices.contains(index) else {
                return BridgeError("No recently closed session to restore")
            }
            context.restore(index)
            return Self.session(index: index, url: context.recentlyClosedURLs[index])

        default:
            return nil
        }
    }

    private static func session(index: Int, url: URL) -> [String: Any] {
        let sessionId = String(index)
        return [
            "lastModified": Date().timeIntervalSince1970,
            "tab": [
                "sessionId": sessionId,
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
