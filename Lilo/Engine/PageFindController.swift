import OSLog
import WebKit

/// Find-in-page state and operations for a single web view.
@MainActor
final class PageFindController: NSObject {
    /// A search's outcome; `matchIndex` (1-based) and `matchCount` are nil when WebKit does not count.
    struct Result: Equatable {
        let query: String
        let matchFound: Bool
        var matchIndex: Int?
        var matchCount: Int?
    }

    /// Most matches WebKit counts for a search: past it, a search reports no count.
    static let maxMatchCount = 1000

    private let webView: WKWebView
    private var query = ""
    private var caseSensitive = false
    /// Whether WebKit counts matches and reports them to this `_WKFindDelegate`.
    private let countsMatches: Bool
    /// Each search's result, Find Next and Find Previous included.
    var onResult: ((Result) -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        let setFindDelegate = NSSelectorFromString("_setFindDelegate:")
        countsMatches = [setFindDelegate, NSSelectorFromString("_findString:options:maxCount:"), NSSelectorFromString("_hideFindUI")]
            .allSatisfy(webView.responds(to:))
        super.init()
        if countsMatches { webView.perform(setFindDelegate, with: self) }
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

    func find(_ query: String, caseSensitive: Bool) {
        self.query = query
        self.caseSensitive = caseSensitive
        if countsMatches {
            // WebKit numbers matches from the first one a search selects, wherever it is: a search from the top, with
            // WebKit's count reset, numbers them in page order.
            webView.perform(NSSelectorFromString("_hideFindUI"))
            WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("getSelection().removeAllRanges()", in: nil, in: .defaultClient)
        }
        search(backwards: false)
    }

    /// What Find Next looks for: the last search, else, as in Safari, the system find pasteboard (Cmd-E in any app).
    var findAgainString: String { query.isEmpty ? NSPasteboard(name: .find).string(forType: .string) ?? "" : query }

    func findNext() { findAgain(backwards: false) }
    func findPrevious() { findAgain(backwards: true) }

    /// Ends the find session like Safari: the last match stays selected, only WebKit's find state goes. The search
    /// itself stays, for Find Next and the find bar's next opening.
    func dismiss() {
        guard !query.isEmpty else { return }
        let hideFindUI = NSSelectorFromString("_hideFindUI")
        if webView.responds(to: hideFindUI) { webView.perform(hideFindUI) }
    }

    private func findAgain(backwards: Bool) {
        query = findAgainString
        guard !query.isEmpty else { return }
        search(backwards: backwards)
    }

    private func search(backwards: Bool) {
        PerfSignposts.energy.emitEvent("pageFind")
        if countsMatches {
            // `_WKFindOptions`: CaseInsensitive, Backwards, WrapAround, DetermineMatchIndex.
            let options: UInt = (caseSensitive ? 0 : 1) | (backwards ? 1 << 3 : 0) | 1 << 4 | 1 << 9
            WebViewPrivateAccessors(webView).findString(query, options: options, maxCount: UInt(Self.maxMatchCount))
            return
        }
        let query = query
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true; config.caseSensitive = caseSensitive
        Task {
            let found = (try? await webView.find(query, configuration: config))?.matchFound == true
            onResult?(Result(query: query, matchFound: found))
        }
    }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFindMatches matches: UInt, for string: String, matchIndex: Int) {
        // Past `maxCount`, WebKit reports NSNotFound matches.
        let counted = matches <= Self.maxMatchCount && matchIndex >= 0 && matchIndex < matches
        onResult?(Result(query: string, matchFound: true, matchIndex: counted ? matchIndex + 1 : nil, matchCount: counted ? Int(matches) : nil))
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFind string: String) {
        onResult?(Result(query: string, matchFound: false, matchCount: 0))
    }
}
