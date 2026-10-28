import AppKit
import WebKit

/// Hosts the Document Picture-in-Picture window a page opened: its popup web view, in an always-on-top panel.
/// One per browser window; a new window replaces the previous one.
@MainActor
final class DocumentPiPController: NSObject, WKUIDelegate, NSWindowDelegate {
    private(set) var webView: WKWebView?
    private(set) var openerId: UUID?
    /// Opened by Lilo when its tab was left rather than by the page: returning to the tab closes it.
    var wasAutoEntered = false
    var onClosed: ((UUID) -> Void)?

    private weak var opener: WKWebViewTab?
    private var panel: NSPanel?

    private static let defaultSize = NSSize(width: 400, height: 300)
    private static let screenMargin: CGFloat = 24

    /// Lets `engine`'s next `window.open` become its PiP window. Never in an agent tab, whose popups open as tabs.
    func prepare(_ engine: WKWebViewTab, size: NSSize) -> Bool {
        guard !engine.isAgentControlled else { return false }
        engine.pendingDocumentPiPSize = size
        // Opening automatically on a tab switch carries no user gesture; createWebViewWith turns this off again.
        engine.wkWebView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return true
    }

    /// The popup WebKit hands back to the page as its PiP window, shown in the floating panel.
    func open(configuration: WKWebViewConfiguration, size: NSSize, opener: WKWebViewTab) -> WKWebView {
        close()
        let contentSize = size.width > 0 && size.height > 0 ? size : Self.defaultSize
        let webView = WKWebView(frame: NSRect(origin: .zero, size: contentSize), configuration: configuration)
        webView.uiDelegate = self
        self.webView = webView
        self.opener = opener
        openerId = opener.id
        opener.documentPiPCloser = { [weak self] in self?.close() }
        float()
        panel?.setContentSize(contentSize)
        return webView
    }

    /// Shows the PiP window in the floating panel.
    func float() {
        guard let webView else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let contentView = panel.contentView else { return }
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        if webView.superview !== contentView { contentView.addSubview(webView) }
        panel.orderFrontRegardless()
    }

    /// `window.resizeTo` sizes the whole window, as the page reads it from `outerWidth` and `outerHeight`.
    /// Takes the panel off screen while the PiP window shows in the sidebar dock.
    func hidePanel() {
        panel?.orderOut(nil)
    }

    /// The screen of the floating panel, while it shows.
    var panelScreen: NSScreen? { panel?.isVisible == true ? panel?.screen : nil }

    func resize(to size: NSSize) {
        guard size.width > 0, size.height > 0, let panel else { return }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
    }

    /// Closes the PiP window: the page gets `pagehide` on it, and `documentPictureInPicture.window` goes back to null.
    func close() {
        guard let webView, let openerId else { return }
        self.webView = nil
        self.openerId = nil
        wasAutoEntered = false
        opener?.documentPiPCloser = nil
        opener = nil
        webView.uiDelegate = nil
        webView.perform(NSSelectorFromString("_close"))
        webView.removeFromSuperview()
        panel?.orderOut(nil)
        onClosed?(openerId)
    }

    private func makePanel() -> NSPanel {
        // Non-activating: muting the call from the PiP window leaves the app the user works in at the front.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Out of the user's own screen share: the others see what is shared, not the call's controls.
        panel.sharingType = .none
        panel.delegate = self
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.defaultSize.width - Self.screenMargin, y: visible.minY + Self.screenMargin))
        }
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            if webView === self.webView { close() }
        }
    }

    /// The window frame WebKit sizes `window.open` features and `resizeTo` against (WKUIDelegatePrivate).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    nonisolated func webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler completion: @escaping @MainActor @Sendable (CGRect) -> Void) {
        MainActor.assumeIsolated {
            completion(webView === self.webView ? panel?.frame ?? .zero : .zero)
        }
    }

    /// `window.resizeTo` of the PiP window (WKUIDelegatePrivate); Lilo keeps the window where it placed it.
    @objc(_webView:setWindowFrame:)
    nonisolated func webView(_ webView: WKWebView, setWindowFrame frame: CGRect) {
        MainActor.assumeIsolated {
            if webView === self.webView { resize(to: frame.size) }
        }
    }
}
