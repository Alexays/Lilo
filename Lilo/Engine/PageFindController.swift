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
        let script = "window.getSelection()?.toString() || ''"
        let selected = (try? await webView.evaluateJavaScript(script)) as? String
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

    func findNext() { performFind(backwards: false) }
    func findPrevious() { performFind(backwards: true) }

    func dismiss() {
        query = ""
        caseSensitive = false
        Task { _ = try? await webView.evaluateJavaScript("window.getSelection().removeAllRanges()") }
    }

    private func performFind(backwards: Bool) {
        guard !query.isEmpty else { return }
        PerfSignposts.energy.emitEvent("pageFind")
        Task {
            let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true; config.caseSensitive = caseSensitive
            _ = try? await webView.find(query, configuration: config)
        }
    }
}
