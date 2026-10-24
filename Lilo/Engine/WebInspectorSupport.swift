import WebKit

@MainActor
enum WebInspectorSupport {
    static func prepare(configuration: WKWebViewConfiguration) {
        let preferences = configuration.preferences
        // KVC resolves this key to the private `_setDeveloperExtrasEnabled:`; without it the write raises.
        guard preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) else { return }
        preferences.setValue(true, forKey: "developerExtrasEnabled")
    }
    /// The built-in inspector needs only developer extras; `isInspectable` also publishes every page as a
    /// remote target to Safari's Develop menu, so release builds leave it off.
    static func enable(for webView: WKWebView) {
        #if DEBUG
        webView.isInspectable = true
        #endif
    }
    static func isAvailable(for webView: WKWebView) -> Bool { inspector(for: webView)?.responds(to: NSSelectorFromString("show")) ?? false }
    static func show(for webView: WKWebView) -> Bool { callVoid("show", onInspectorFor: webView) }
    static func showConsole(for webView: WKWebView) -> Bool { callVoid("showConsole", onInspectorFor: webView) }
    static func showResources(for webView: WKWebView) -> Bool { callVoid("showResources", onInspectorFor: webView) }
    static func toggleElementSelection(for webView: WKWebView) -> Bool { callVoid("toggleElementSelection", onInspectorFor: webView) }
    static func togglePageProfiling(for webView: WKWebView) -> Bool { callVoid("togglePageProfiling", onInspectorFor: webView) }
    /// Connects the inspector without showing it, and returns its frontend web view.
    static func connect(for webView: WKWebView) -> WKWebView? {
        let selector = NSSelectorFromString("inspectorWebView")
        guard callVoid("connect", onInspectorFor: webView), let inspector = inspector(for: webView), inspector.responds(to: selector) else { return nil }
        return inspector.perform(selector)?.takeUnretainedValue() as? WKWebView
    }
    static func close(for webView: WKWebView) -> Bool { callVoid("close", onInspectorFor: webView) }
    static func isConnected(for webView: WKWebView) -> Bool { callBool("isConnected", onInspectorFor: webView) ?? false }
    static func isVisible(for webView: WKWebView) -> Bool { callBool("isVisible", onInspectorFor: webView) ?? false }
    static func isElementSelectionActive(for webView: WKWebView) -> Bool { callBool("isElementSelectionActive", onInspectorFor: webView) ?? false }
    static func isPageProfilingActive(for webView: WKWebView) -> Bool { callBool("isProfilingPage", onInspectorFor: webView) ?? false }

    private static func inspector(for webView: WKWebView) -> NSObject? {
        let sel = NSSelectorFromString("_inspector")
        guard webView.responds(to: sel) else { return nil }
        return webView.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private static func callVoid(_ selectorName: String, onInspectorFor webView: WKWebView) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard let inspector = inspector(for: webView), inspector.responds(to: selector) else { return false }
        _ = inspector.perform(selector)
        return true
    }

    private static func callBool(_ selectorName: String, onInspectorFor webView: WKWebView) -> Bool? {
        inspector(for: webView).flatMap { WebViewPrivateAccessors($0).bool(selectorName) }
    }
}
