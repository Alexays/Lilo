import AppKit
import WebKit

/// A page popup (`window.open` asking for a popup): a small window of its own, or a peek over the
/// opener's content in single-window mode. Its engine stays out of the tab list until the user opens
/// it as a tab, which keeps the live page and its `window.opener`.
@MainActor
final class PagePopupController: NSObject, NSWindowDelegate {
    let engine: WKWebViewTab
    let openerTabId: UUID
    /// The peek shown over the opener's content; nil when the popup has its own window.
    let peekView: PagePeekView?
    private(set) var window: NSWindow?
    /// A link the user peeked, not a page's own popup: a window shows one at a time.
    var isLinkPeek = false
    /// The site of the pinned or bookmarked tab whose link to another site this peek took.
    var openerSite: String?
    /// The popup as extensions see it: a popup window holding one tab. Retired by the owner on close.
    var extensionWindow: WindowExtensionAdapter?
    private let header: PopupHeaderView
    private var observations: [NSKeyValueObservation] = []
    /// Set once the engine leaves for a tab or is torn down, so it is never torn down twice.
    private var isDetached = false

    /// The opener can take the popup as a split pane; the split button shows only then.
    var canOpenInSplit: Bool {
        get { header.showsSplitButton }
        set { header.showsSplitButton = newValue }
    }

    /// The owner makes the engine a tab: a split pane beside the opener when the flag is set.
    var onOpenAsTab: ((PagePopupController, Bool) -> Void)?
    var onClose: ((PagePopupController) -> Void)?

    /// `topLeft` is the page's requested screen position (CSS pixels from the primary screen's top
    /// left); without one the window is centered on `parent`.
    init(engine: WKWebViewTab, openerTabId: UUID, contentSize: NSSize, topLeft: NSPoint?, inPeek: Bool, parent: NSWindow?) {
        self.engine = engine
        self.openerTabId = openerTabId
        header = PopupHeaderView(inWindow: !inPeek)
        peekView = inPeek ? PagePeekView(header: header, content: engine.view, preferredSize: contentSize) : nil
        super.init()
        header.onOpenAsTab = { [weak self] in self?.openAsTab() }
        header.onOpenInSplit = { [weak self] in self?.openAsTab(inSplit: true) }
        header.onClose = { [weak self] in self?.requestClose() }
        peekView?.onDismiss = { [weak self] in self?.requestClose() }
        if peekView == nil { showWindow(contentSize: contentSize, topLeft: topLeft, parent: parent) }
        observations = [
            engine.wkWebView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshHost() } },
            engine.wkWebView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshProgress() } },
            engine.wkWebView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshProgress() } }
        ]
        refreshHost()
        refreshProgress()
    }

    private func showWindow(contentSize: NSSize, topLeft: NSPoint?, parent: NSWindow?) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty compact toolbar gives the title bar the header's height and centers the traffic lights.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = parent?.backgroundColor ?? .windowBackgroundColor
        window.contentMinSize = NSSize(width: 240, height: 160)
        window.delegate = self

        // The header lives in the title bar view: content under a transparent title bar never gets its clicks.
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            header.frame = titlebar.bounds
            header.autoresizingMask = [.width, .height]
            titlebar.addSubview(header, positioned: .above, relativeTo: nil)
        }
        if let contentView = window.contentView {
            engine.view.frame = contentView.bounds
            engine.view.autoresizingMask = [.width, .height]
            contentView.addSubview(engine.view)
        }

        let screen = topLeft.flatMap { point in NSScreen.screens.first { $0.frame.contains(Self.appKitPoint(point)) } }
            ?? parent?.screen ?? NSScreen.main
        var frame = window.frame
        if let topLeft {
            let point = Self.appKitPoint(topLeft)
            frame.origin = NSPoint(x: point.x, y: point.y - frame.height)
        } else if let parent {
            frame.origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2)
        }
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
        if parent == nil { window.center() }
        self.window = window
        // A child window stays above the browser window and follows it, in full screen too.
        parent?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(engine.wkWebView)
    }

    /// Web screen coordinates start at the primary screen's top left; AppKit's at its bottom left.
    private static func appKitPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    private func refreshHost() {
        let url = engine.currentURL
        let host = url?.host ?? ""
        let insecure = url?.scheme == "http"
        window?.title = insecure ? "Not Secure".localized + " - " + host : host
        header.setHost(host, insecure: insecure)
    }

    private func refreshProgress() {
        let webView = engine.wkWebView
        // A load starts near zero: show a sliver at once so the line reads as started.
        header.progress = webView.isLoading ? max(0.08, webView.estimatedProgress) : nil
    }

    /// Asks for a capture permission in a sheet on the popup window. False when the popup has no
    /// window (a peek): its opener's tab prompts instead.
    func askPermission(_ type: String, completion: @escaping (Bool) -> Void) -> Bool {
        guard let window else { return false }
        Self.askPermission(type, for: engine, in: window, completion: completion)
        return true
    }

    /// Asks for a capture permission for `engine`'s page in a sheet on `window`.
    static func askPermission(_ type: String, for engine: WKWebViewTab, in window: NSWindow, completion: @escaping (Bool) -> Void) {
        let host = engine.currentURL?.host ?? ""
        let messages = [
            "camera": "%@ wants to use your camera".localized,
            "microphone": "%@ wants to use your microphone".localized,
            "camera and microphone": "%@ wants to use your camera and microphone".localized
        ]
        let alert = NSAlert()
        alert.messageText = String(format: messages[type] ?? "%@ wants to use your camera or microphone".localized, host)
        alert.addButton(withTitle: "Allow".localized)
        alert.addButton(withTitle: "Deny".localized)
        alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
    }

    /// Closes on the user's request, once the page's beforeunload handler lets it: when it objects,
    /// WebKit asks the user and comes back through `webViewDidClose`.
    func requestClose() {
        guard engine.pageRequestedClose || engine.tryClose() else { return }
        close()
    }

    func close() {
        if let window { window.close() } else { finish() }
    }

    /// Hands the engine over: the owner makes it a tab, which re-parents its view.
    func openAsTab(inSplit: Bool = false) {
        isDetached = true
        engine.view.removeFromSuperview()
        onOpenAsTab?(self, inSplit)
        close()
    }

    /// File > Open as Tab in the popup window.
    @objc func openPageAsTab(_ sender: Any?) { openAsTab() }

    /// Cmd+W in the popup window closes the popup, not the tab behind it.
    @objc func closeCurrentTab(_ sender: Any?) { requestClose() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isDetached || engine.pageRequestedClose || engine.tryClose()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { window.parent?.removeChildWindow(window) }
        window = nil
        finish()
    }

    private func finish() {
        observations = []
        onClose?(self)
        onClose = nil
        guard !isDetached else {
            peekView?.removeFromSuperview()
            return
        }
        isDetached = true
        let engine = engine
        guard let peekView, peekView.superview != nil else {
            // Deferred so the caller's stack unwinds before releasing the WKWebView.
            DispatchQueue.main.async { engine.teardown() }
            return
        }
        peekView.dismiss { engine.teardown() }
    }
}

/// The popup's bar: its host in a pill with a lock, "Open in Split", "Open as Tab", copy and close
/// buttons in a peek, and a load progress line along the bottom edge. In a window it sits in the title bar, past
/// the traffic lights.
@MainActor
final class PopupHeaderView: NSView {
    private static let trafficLightsWidth: CGFloat = 78
    private static let minimumPillWidth: CGFloat = 160

    var onOpenAsTab: (() -> Void)?
    var onOpenInSplit: (() -> Void)?
    var onClose: (() -> Void)?
    var showsSplitButton = false {
        didSet {
            splitButton.isHidden = !showsSplitButton
            needsLayout = true
        }
    }
    var progress: Double? {
        get { progressBar.progress }
        set { progressBar.progress = newValue }
    }

    private let inWindow: Bool
    private var titledOpenWidth: CGFloat = 0
    private var iconOpenWidth: CGFloat = 28
    private var host = ""
    private var hostPrefix = ""
    private let pill = PillView()
    private let lockIcon = NSImageView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let progressBar = PopupProgressBar()
    private lazy var openButton: NSButton = {
        let image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open as Tab".localized) ?? NSImage()
        let button = inWindow
            ? NSButton(image: image, target: self, action: #selector(openAsTabAction(_:)))
            : NSButton(title: "Open as Tab".localized, image: image, target: self, action: #selector(openAsTabAction(_:)))
        if inWindow {
            button.isBordered = false
        } else {
            button.bezelStyle = .accessoryBarAction
            button.imagePosition = .imageLeading
        }
        button.toolTip = "Open as Tab".localized
        button.sizeToFit()
        return button
    }()
    private lazy var splitButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Open in Split".localized) ?? NSImage(),
            target: self,
            action: #selector(openInSplitAction(_:))
        )
        if inWindow { button.isBordered = false } else { button.bezelStyle = .accessoryBarAction }
        button.toolTip = "Open in Split".localized
        button.isHidden = true
        return button
    }()
    // Through the responder chain: the window controller copies the shown peek's URL.
    private lazy var copyButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Page URL".localized) ?? NSImage(),
            target: nil,
            action: #selector(MainWindowController.copyCurrentURL(_:))
        )
        button.bezelStyle = .accessoryBarAction
        button.toolTip = "Copy Page URL".localized
        return button
    }()
    private lazy var closeButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close".localized) ?? NSImage(),
            target: self,
            action: #selector(closeAction(_:))
        )
        button.isBordered = false
        button.toolTip = "Close".localized
        return button
    }()

    override var isFlipped: Bool { true }

    init(inWindow: Bool) {
        self.inWindow = inWindow
        super.init(frame: .zero)
        hostLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        // What is left past the registrable domain (see hostText) truncates from the head.
        hostLabel.lineBreakMode = .byTruncatingHead
        pill.addSubview(lockIcon)
        pill.addSubview(hostLabel)
        addSubview(pill)
        addSubview(openButton)
        titledOpenWidth = openButton.frame.width
        if !inWindow {
            openButton.imagePosition = .imageOnly
            iconOpenWidth = openButton.intrinsicContentSize.width
            openButton.imagePosition = .imageLeading
        }
        addSubview(splitButton)
        if !inWindow {
            addSubview(copyButton)
            addSubview(closeButton)
        }
        addSubview(progressBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHost(_ host: String, insecure: Bool) {
        self.host = host
        hostPrefix = insecure ? "Not Secure".localized + " - " : ""
        hostLabel.textColor = insecure ? .systemRed : .labelColor
        lockIcon.image = NSImage(systemSymbolName: insecure ? "exclamationmark.triangle.fill" : "lock.fill", accessibilityDescription: insecure ? nil : "Secure Connection".localized)
        // The host label already starts with "Not Secure".
        lockIcon.setAccessibilityElement(!insecure)
        lockIcon.contentTintColor = insecure ? .systemRed : .systemGreen
        needsLayout = true
    }

    /// The width the label takes for `text`: a truncating label reports an intrinsic width a few points short of it.
    private func labelWidth(_ text: String) -> CGFloat {
        hostLabel.stringValue = text
        return hostLabel.cell?.cellSize.width.rounded(.up) ?? 0
    }

    /// The host whole when it fits `width`, else its subdomains cut in the middle so the registrable domain stays whole.
    private func hostText(fitting width: CGFloat) -> String {
        let whole = hostPrefix + host
        let domain = CookiesBridgeHandler.registrableDomain(of: host)
        let subdomain = host.dropLast(domain.count)
        guard !subdomain.isEmpty, labelWidth(whole) > width else { return whole }
        for keep in stride(from: subdomain.count - 1, to: 0, by: -1) {
            let text = hostPrefix + subdomain.prefix(keep) + "\u{2026}" + domain
            if labelWidth(text) <= width { return text }
        }
        // Too narrow for the domain too: the label cuts its head, with an ellipsis of its own.
        return hostPrefix + domain
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        var trailing = bounds.width - 8
        if !inWindow {
            closeButton.frame = NSRect(x: trailing - 28, y: midY - 14, width: 28, height: 28)
            trailing = closeButton.frame.minX - 4
        }
        let leading: CGFloat = inWindow ? Self.trafficLightsWidth : 10
        // Buttons keep their natural size: a narrow peek first shows "Open as Tab" as its icon, then drops
        // the copy button (Edit > Copy Page URL), so the pill keeps at least the registrable domain.
        let room = trailing - 8 - leading
        let domainPillWidth = labelWidth(hostPrefix + "\u{2026}" + CookiesBridgeHandler.registrableDomain(of: host)) + 40
        let splitWidth = inWindow ? 28 : splitButton.intrinsicContentSize.width
        let splitRoom = showsSplitButton ? splitWidth + 4 : 0
        let copyRoom = inWindow ? 0 : copyButton.intrinsicContentSize.width + 4
        let titled = !inWindow && room - titledOpenWidth - splitRoom - copyRoom >= max(Self.minimumPillWidth, domainPillWidth)
        let openWidth = inWindow ? 28 : titled ? titledOpenWidth : iconOpenWidth
        copyButton.isHidden = inWindow || room - openWidth - splitRoom - copyRoom < domainPillWidth
        if !inWindow { openButton.imagePosition = titled ? .imageLeading : .imageOnly }
        let buttonHeight = inWindow ? 28 : openButton.intrinsicContentSize.height
        openButton.frame = NSRect(x: trailing - openWidth, y: (midY - buttonHeight / 2).rounded(), width: openWidth, height: buttonHeight)
        trailing = openButton.frame.minX
        if showsSplitButton {
            splitButton.frame = NSRect(x: trailing - 4 - splitWidth, y: (midY - buttonHeight / 2).rounded(), width: splitWidth, height: buttonHeight)
            trailing = splitButton.frame.minX
        }
        if !copyButton.isHidden {
            copyButton.frame = NSRect(x: trailing - copyRoom, y: (midY - buttonHeight / 2).rounded(), width: copyRoom - 4, height: buttonHeight)
            trailing = copyButton.frame.minX
        }

        let available = max(0, trailing - 8 - leading)
        let text = hostText(fitting: available - 40)
        let labelSize = NSSize(width: labelWidth(text), height: hostLabel.intrinsicContentSize.height)
        let pillWidth = min(labelSize.width + 40, available)
        // Centered on the bar in a window, like a title; leading in a peek.
        let centeredX = (bounds.width - pillWidth) / 2
        let pillX = inWindow ? min(max(centeredX, leading), leading + available - pillWidth) : leading
        pill.frame = NSRect(x: pillX.rounded(), y: (midY - 13).rounded(), width: pillWidth, height: 26)
        lockIcon.frame = NSRect(x: 11, y: 6, width: 14, height: 14)
        hostLabel.frame = NSRect(x: 30, y: ((26 - labelSize.height) / 2).rounded(), width: max(0, pillWidth - 40), height: labelSize.height)
        progressBar.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
    }

    // Only the buttons take clicks: the rest falls through to the traffic lights and the window drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }

    @objc private func openAsTabAction(_ sender: Any?) { onOpenAsTab?() }
    @objc private func openInSplitAction(_ sender: Any?) { onOpenInSplit?() }
    @objc private func closeAction(_ sender: Any?) { onClose?() }
}

/// A peek over the content: a dimmed backdrop and a centered card with the page, or any view that
/// brings its own header. Esc and a click outside the card, on the backdrop or the chrome, dismiss it.
@MainActor
final class PagePeekView: NSView {
    private static let headerHeight: CGFloat = 44
    private static let margin: CGFloat = 32
    private static let cornerRadius: CGFloat = 14

    var onDismiss: (() -> Void)?

    private let header: NSView?
    private let content: NSView
    private let preferredSize: NSSize
    private let card = FlippedView()
    private let clip = FlippedView()
    private let headerBackground = NSVisualEffectView()
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    override var isFlipped: Bool { true }

    init(header: NSView?, content: NSView, preferredSize: NSSize) {
        self.header = header
        self.content = content
        self.preferredSize = preferredSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor

        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            return shadow
        }()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.masksToBounds = true
        headerBackground.material = .headerView
        headerBackground.blendingMode = .withinWindow

        content.autoresizingMask = []
        clip.addSubview(content)
        if let header {
            clip.addSubview(headerBackground)
            clip.addSubview(header)
        }
        card.addSubview(clip)
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(240, min(preferredSize.width, bounds.width - 2 * Self.margin))
        let headerHeight = header == nil ? 0 : Self.headerHeight
        let height = max(160, min(preferredSize.height + headerHeight, bounds.height - 2 * Self.margin))
        card.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        clip.frame = card.bounds
        headerBackground.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        header?.frame = headerBackground.frame
        content.frame = NSRect(x: 0, y: headerHeight, width: width, height: height - headerHeight)
    }

    /// Fades the backdrop in and grows the card into place, unless the user asked for less motion.
    func present() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        layoutSubtreeIfNeeded()
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 1
        }
        let bounds = card.bounds
        var from = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        from = CATransform3DScale(from, 0.96, 0.96, 1)
        from = CATransform3DTranslate(from, -bounds.midX, -bounds.midY, 0)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = from
        grow.toValue = CATransform3DIdentity
        grow.duration = 0.24
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        card.layer?.add(grow, forKey: "present")
    }

    /// Fades out, then leaves the view hierarchy and runs `completion`.
    func dismiss(completion: @escaping @MainActor () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            removeFromSuperview()
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                self?.alphaValue = 1
                completion()
            }
        })
    }

    // Swallowed: the click monitor dismisses, and the content under the backdrop must not get it.
    override func mouseDown(with event: NSEvent) {}

    // Anything in the card without a cursor of its own would otherwise get the one of the view underneath.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    // Esc dismisses even when the page keeps the key to itself, but never cancels an IME composition.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        guard window != nil else { return }
        // A monitor, as the chrome lies outside this view; the click still goes on to what it hit.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let eventWindow = event.window
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, eventWindow === self.window,
                      !self.card.frame.contains(self.convert(location, from: nil)) else { return }
                self.onDismiss?()
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let eventWindow = event.window
            let dismissed = MainActor.assumeIsolated {
                guard let self, eventWindow === self.window,
                      (self.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
                self.onDismiss?()
                return true
            }
            return dismissed ? nil : event
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The host's rounded backdrop; a layer color, so it follows the appearance through `updateLayer`.
final class PillView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 13
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.08 : 0.6).cgColor
    }
}

/// The accent line tracking a popup's page load; hidden when the page is idle.
final class PopupProgressBar: NSView {
    private let fill = CALayer()

    var progress: Double? {
        didSet {
            isHidden = progress == nil
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        fill.backgroundColor = NSColor(cssHex: "#5865f2")?.cgColor
        layer?.addSublayer(fill)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * (progress ?? 0), height: bounds.height)
    }
}
