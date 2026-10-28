import AppKit
import WebKit

/// Hosts the Document Picture-in-Picture window a page opened: its popup web view, in an always-on-top panel
/// that snaps to the corners of its screen and remembers its corner per screen. One per browser window; a new
/// window replaces the previous one.
@MainActor
final class DocumentPiPController: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    private(set) var webView: WKWebView?
    private(set) var openerId: UUID?
    /// Opened by Lilo when its tab was left rather than by the page: returning to the tab closes it.
    var wasAutoEntered = false
    /// The opener's id, and whether a new PiP window replaces this one (the dock then keeps its slot).
    var onClosed: ((UUID, Bool) -> Void)?
    /// The hover bar's back button: the window shows the opener's tab, in whatever space it lives.
    var onReturnToTab: ((UUID) -> Void)?

    private weak var opener: WKWebViewTab?
    /// The screen the user dragged the panel to, while it stays open: it then stays there rather than docking.
    private(set) var movedToScreen: NSScreen?
    private var panel: NSPanel?
    private let content = PiPContentView()

    private static let defaultSize = NSSize(width: 400, height: 300)
    static let screenMargin: CGFloat = 16

    /// Lets `engine`'s next blank `window.open` become its PiP window: after a user activation, as in Chrome, or in
    /// answer to Lilo's automatic opening. Never in an agent tab, whose popups open as tabs.
    func prepare(_ engine: WKWebViewTab, size: NSSize, userActivated: Bool, automatic: Bool) -> Bool {
        guard userActivated || automatic, !engine.isAgentControlled else { return false }
        engine.pendingDocumentPiPSize = size
        // The page's `window.open` comes after this round trip, past its gesture, and the automatic opening has none:
        // the next PiP window, commit or teardown turns this off again.
        engine.wkWebView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return true
    }

    /// The popup WebKit hands back to the page as its PiP window, shown in the floating panel at the corner it
    /// last had on the screen under the pointer.
    func open(configuration: WKWebViewConfiguration, size: NSSize, opener: WKWebViewTab) -> WKWebView {
        close(replacing: true)
        let contentSize = size.width > 0 && size.height > 0 ? size : Self.defaultSize
        let webView = WKWebView(frame: NSRect(origin: .zero, size: contentSize), configuration: configuration)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        self.webView = webView
        self.opener = opener
        openerId = opener.id
        opener.documentPiPCloser = { [weak self] in self?.close() }
        // The page draws its PiP window: a hidden or covered browser window must not throttle it.
        opener.setWindowOcclusionDetection(false)
        let panel = panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let saved = UserDefaults.standard.string(forKey: Self.frameKey(for: screen)).map(NSRectFromString)
            let origin = saved?.origin ?? NSPoint(x: screen.visibleFrame.maxX, y: screen.visibleFrame.minY)
            let size = Self.cappedSize(contentSize, in: screen.visibleFrame)
            panel.setFrame(Self.snappedFrame(NSRect(origin: origin, size: size), in: screen.visibleFrame), display: false)
        }
        float()
        return webView
    }

    /// Shows the PiP window in the floating panel.
    func float() {
        guard let webView, let panel else { return }
        content.host(webView)
        panel.orderFrontRegardless()
    }

    /// Takes the panel off screen while the PiP window shows in the sidebar dock.
    func hidePanel() {
        panel?.orderOut(nil)
    }

    /// `window.resizeTo` sizes the whole window, as the page reads it from `outerWidth` and `outerHeight`; the
    /// panel keeps its corner.
    func resize(to size: NSSize) {
        guard size.width > 0, size.height > 0, let panel, let visibleFrame = panel.screen?.visibleFrame else { return }
        let resized = NSRect(origin: panel.frame.origin, size: Self.cappedSize(size, in: visibleFrame))
        panel.setFrame(Self.snappedFrame(resized, in: visibleFrame), display: true)
    }

    /// The user let go of the panel: it snaps to the nearest corner, remembered for that screen.
    func endMove() {
        guard let panel, let screen = panel.screen else { return }
        let snapped = Self.snappedFrame(panel.frame, in: screen.visibleFrame)
        panel.setFrame(snapped, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromRect(snapped), forKey: Self.frameKey(for: screen))
        movedToScreen = screen
    }

    func returnToTab() {
        guard let openerId else { return }
        close()
        onReturnToTab?(openerId)
    }

    /// Closes the PiP window: the page gets `pagehide` on it, and `documentPictureInPicture.window` goes back to null.
    func close() {
        close(replacing: false)
    }

    private func close(replacing: Bool) {
        guard let webView, let openerId else { return }
        self.webView = nil
        self.openerId = nil
        wasAutoEntered = false
        movedToScreen = nil
        opener?.documentPiPCloser = nil
        opener?.setWindowOcclusionDetection(true)
        opener = nil
        webView.uiDelegate = nil
        webView.perform(NSSelectorFromString("_close"))
        webView.removeFromSuperview()
        panel?.orderOut(nil)
        onClosed?(openerId, replacing)
    }

    /// `frame` moved to the corner of `visibleFrame` nearest its center, `screenMargin` inside.
    static func snappedFrame(_ frame: NSRect, in visibleFrame: NSRect) -> NSRect {
        let left = frame.midX < visibleFrame.midX, bottom = frame.midY < visibleFrame.midY
        return NSRect(
            x: left ? visibleFrame.minX + screenMargin : visibleFrame.maxX - screenMargin - frame.width,
            y: bottom ? visibleFrame.minY + screenMargin : visibleFrame.maxY - screenMargin - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// At most half the screen each way, as a PiP window is a companion to the page, never a cover over the screen.
    static func cappedSize(_ size: NSSize, in visibleFrame: NSRect) -> NSSize {
        // Whole points: AppKit rounds a window frame, which would land half a point past an odd screen's half.
        NSSize(width: max(160, min(size.width, (visibleFrame.width / 2).rounded(.down))),
               height: max(120, min(size.height, (visibleFrame.height / 2).rounded(.down))))
    }

    /// Per display, not per model name: two monitors of one model each keep their own corner.
    static func frameKey(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(nil, uuid) as String? else {
            return "LiloDocumentPiPFrame." + screen.localizedName
        }
        return "LiloDocumentPiPFrame." + identifier
    }

    private func makePanel() -> NSPanel {
        // Borderless: the page fills the window, Lilo's controls show over it on hover. Non-activating: muting the
        // call from the PiP window leaves the app the user works in at the front.
        let panel = PiPPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentMinSize = NSSize(width: 160, height: 120)
        // Out of the user's own screen share: the others see what is shared, not the call's controls.
        panel.sharingType = .none
        panel.delegate = self
        panel.contentView = content
        content.onReturnToTab = { [weak self] in self?.returnToTab() }
        content.onClose = { [weak self] in self?.close() }
        content.onMoveEnded = { [weak self] in self?.endMove() }
        return panel
    }

    /// The page fills its PiP window from its own document: like Chrome, the window never loads another page.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            let blank = url == nil || url?.absoluteString == "about:blank"
            decisionHandler(navigationAction.targetFrame?.isMainFrame == false || blank ? .allow : .cancel)
        }
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

    /// `window.resizeTo` of the PiP window (WKUIDelegatePrivate); Lilo keeps the window at its corner.
    @objc(_webView:setWindowFrame:)
    nonisolated func webView(_ webView: WKWebView, setWindowFrame frame: CGRect) {
        MainActor.assumeIsolated {
            if webView === self.webView { resize(to: frame.size) }
        }
    }
}

/// Borderless panels refuse key status by default; the PiP page needs it for its controls' keyboard handling.
private final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Rounded host of the PiP page, with Lilo's back and close buttons in a bar shown while the pointer is over it.
/// The bar also drags the window: the page takes every other click.
private final class PiPContentView: NSView {
    var onReturnToTab: (() -> Void)?
    var onClose: (() -> Void)?
    var onMoveEnded: (() -> Void)?

    private let bar = PiPHoverBar()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        bar.isHidden = true
        bar.onReturnToTab = { [weak self] in self?.onReturnToTab?() }
        bar.onClose = { [weak self] in self?.onClose?() }
        bar.onMoveEnded = { [weak self] in self?.onMoveEnded?() }
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func host(_ webView: NSView) {
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        if webView.superview !== self { addSubview(webView, positioned: .below, relativeTo: bar) }
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: bounds.maxY - PiPHoverBar.height, width: bounds.width, height: PiPHoverBar.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // Always: the panel never activates the app, so it is rarely in a key window.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { bar.isHidden = false }
    override func mouseExited(with event: NSEvent) { bar.isHidden = true }
}

private final class PiPHoverBar: NSView {
    static let height: CGFloat = 28

    var onReturnToTab: (() -> Void)?
    var onClose: (() -> Void)?
    var onMoveEnded: (() -> Void)?

    private lazy var returnButton = button("arrow.uturn.backward", label: "Back to tab".localized, action: #selector(returnPressed))
    private lazy var closeButton = button("xmark", label: "Close".localized, action: #selector(closePressed))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        addSubview(returnButton)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = label
        button.target = self
        button.action = action
        return button
    }

    override func layout() {
        super.layout()
        returnButton.frame = NSRect(x: 6, y: 4, width: 20, height: 20)
        closeButton.frame = NSRect(x: bounds.maxX - 26, y: 4, width: 20, height: 20)
    }

    override func mouseDown(with event: NSEvent) {
        // Runs the drag to its end, so the panel snaps once the user lets go.
        window?.performDrag(with: event)
        onMoveEnded?()
    }

    @objc private func returnPressed() { onReturnToTab?() }
    @objc private func closePressed() { onClose?() }
}
