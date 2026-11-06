import WebKit

/// Gap API handler for `chrome.offscreen`. Loads the document in a hidden web view built from the
/// extension context's own configuration, so chrome.runtime messaging reaches it natively. The view
/// is never put in a window. One document per (profile, extension), as in Chrome.
@MainActor
final class OffscreenBridgeHandler: NSObject, GapHandler, WKNavigationDelegate, WKUIDelegate {
    let gapActions: Set<String> = [
        "offscreen.createDocument",
        "offscreen.closeDocument",
        "offscreen.documentUrl"
    ]

    private struct Document {
        weak var context: WKWebExtensionContext?
        let webView: WKWebView
    }

    /// Keyed by "profileId/extensionId".
    private var documents: [String: Document] = [:]
    /// createDocument resolves once the page has loaded, so a message sent right after reaches it.
    private var pendingLoads: [ObjectIdentifier: CheckedContinuation<Error?, Never>] = [:]
    nonisolated(unsafe) private var unloadObserver: Any?

    override init() {
        super.init()
        // A disabled, unloaded or uninstalled extension's document closes with it.
        unsafe unloadObserver = NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard let profileId = note.userInfo?["profileId"] as? UUID, let extensionId = note.userInfo?["extensionId"] as? String else { return }
            MainActor.assumeIsolated { self?.closeDocument("\(profileId)/\(extensionId)") }
        }
    }

    deinit {
        unsafe unloadObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry, extensionId = call.extensionId
        guard let context = registry.context(for: extensionId) else {
            return BridgeError("Extension not loaded")
        }
        let key = "\(registry.profileId)/\(extensionId)"
        // A reloaded extension has a new context: the previous one's document is gone with it.
        if let existing = documents[key], existing.context !== context { closeDocument(key) }

        switch call.action {
        case "offscreen.createDocument":
            guard documents[key] == nil else { return BridgeError("Only a single offscreen document may be created.") }
            guard let path = call.string("url"),
                  let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
                  url.scheme == context.baseURL.scheme, url.host == context.baseURL.host,
                  let configuration = context.pageWebViewConfiguration else {
                return BridgeError("Invalid offscreen document url")
            }
            // The view is never in a window, so its page counts as hidden: it runs at full speed, as WebKit's own
            // background and offscreen pages do. These preferences are this configuration's own.
            let preferences = configuration.preferences
            preferences.inactiveSchedulingPolicy = .none
            var settings = ["hiddenPageDOMTimerThrottlingEnabled": false, "pageVisibilityBasedProcessSuppressionEnabled": false]
            // WebKit knows no clipboardRead permission; with it, Chrome lets the document paste without a gesture.
            if (context.webExtension.manifest["permissions"] as? [String])?.contains("clipboardRead") == true {
                settings["DOMPasteAllowed"] = true
                settings["javaScriptCanAccessClipboard"] = true
            }
            for (key, value) in settings
            where preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
                preferences.setValue(value, forKey: key)
            }
            let documentView = WKWebView(frame: .zero, configuration: configuration)
            documentView.navigationDelegate = self
            documentView.uiDelegate = self
            registry.frameCookies.watch(documentView)
            documents[key] = Document(context: context, webView: documentView)
            let error = await withCheckedContinuation { continuation in
                pendingLoads[ObjectIdentifier(documentView)] = continuation
                documentView.load(URLRequest(url: url))
            }
            guard let error else { return nil }
            if documents[key]?.webView === documentView { closeDocument(key) }
            return BridgeError(error.localizedDescription)

        case "offscreen.closeDocument":
            guard documents[key] != nil else { return BridgeError("No current offscreen document.") }
            closeDocument(key)
            return nil

        case "offscreen.documentUrl":
            return documents[key]?.webView.url?.absoluteString

        default:
            return nil
        }
    }

    private func closeDocument(_ key: String) {
        guard let document = documents.removeValue(forKey: key) else { return }
        document.webView.navigationDelegate = nil
        document.webView.uiDelegate = nil
        document.webView.stopLoading()
        finishLoad(of: document.webView, error: CancellationError())
    }

    private func finishLoad(of webView: WKWebView, error: Error?) {
        pendingLoads.removeValue(forKey: ObjectIdentifier(webView))?.resume(returning: error)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finishLoad(of: webView, error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finishLoad(of: webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finishLoad(of: webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let key = documents.first(where: { $0.value.webView === webView })?.key { closeDocument(key) }
    }

    // MARK: - WKUIDelegate

    /// A document that closes itself with window.close() is gone, as in Chrome, and another may be created.
    func webViewDidClose(_ webView: WKWebView) {
        if let key = documents.first(where: { $0.value.webView === webView })?.key { closeDocument(key) }
    }
}
