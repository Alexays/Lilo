import OSLog
import WebKit

/// Find-in-page state and operations for a single web view.
@MainActor
final class PageFindController {
    private let webView: WKWebView
    private var query = ""
    private var caseSensitive = false

    init(webView: WKWebView) {
        self.webView = webView
    }

    func selectedText() async -> String? {
        let accessors = WebViewPrivateAccessors(webView)
        // `_WKSelectionAttributeIsRange`: a caret or no selection has no text to seed the find bar with.
        if let attributes = accessors.int("_selectionAttributes"), attributes & 1 << 1 == 0 { return nil }
        let persistent = webView.configuration.websiteDataStore.isPersistent
        let selected: String? = await withCheckedContinuation { continuation in
            // The find pasteboard is shared with every app, so a private space never writes to it.
            if persistent, accessors.takeFindStringFromSelection(completion: { continuation.resume(returning: $0) }) { return }
            accessors.evaluateWithoutUserGesture("window.getSelection()?.toString() || ''", in: nil, in: .defaultClient) {
                continuation.resume(returning: $0 as? String)
            }
        }
        let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func find(_ query: String, caseSensitive: Bool) async -> Bool {
        self.query = query
        self.caseSensitive = caseSensitive
        let config = WKFindConfiguration(); config.caseSensitive = caseSensitive; config.wraps = true
        PerfSignposts.energy.emitEvent("pageFind")
        return (try? await webView.find(query, configuration: config))?.matchFound == true
    }

    /// What Find Next looks for: the current search, else, as in Safari, the system find pasteboard (Cmd-E in any app).
    var findAgainString: String { query.isEmpty ? NSPasteboard(name: .find).string(forType: .string) ?? "" : query }

    func findNext() { performFind(backwards: false) }
    func findPrevious() { performFind(backwards: true) }

    /// Ends the find session like Safari: the last match stays selected, only WebKit's find state goes.
    func dismiss() {
        guard !query.isEmpty else { return }
        query = ""
        caseSensitive = false
        let hideFindUI = NSSelectorFromString("_hideFindUI")
        if webView.responds(to: hideFindUI) { webView.perform(hideFindUI) }
    }

    private func performFind(backwards: Bool) {
        query = findAgainString
        guard !query.isEmpty else { return }
        PerfSignposts.energy.emitEvent("pageFind")
        Task {
            let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true; config.caseSensitive = caseSensitive
            _ = try? await webView.find(query, configuration: config)
        }
    }
}
