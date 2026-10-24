import AppKit
import WebKit

/// A Little window: one page in a small window of its own, outside every Space's tab list, with a
/// compact address row, Copy URL and "Open in <Space>". Its page runs in the profile of the Space
/// it opened for; closing the window sends the page to Recently Closed.
@MainActor
final class LittleWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let frameName = "LiloLittleWindow"
    static let defaultSize = NSSize(width: 900, height: 640)

    let engine: WKWebViewTab
    /// "Open in" targets it, and the closed page reopens there.
    let spaceId: UUID
    /// A Space whose tabs run in another store gets the page reloaded rather than this live engine.
    let dataStore: WKEngineDataStore
    let window: NSWindow
    /// The browser window whose delegate methods serve the page.
    weak var owner: MainWindowController?
    private let header = LittleWindowHeaderView()
    private var observations: [NSKeyValueObservation] = []
    /// Set once the engine leaves for a tab or is torn down, so it is never torn down twice.
    private var isDetached = false

    init(engine: WKWebViewTab, spaceId: UUID, dataStore: WKEngineDataStore, owner: MainWindowController) {
        self.engine = engine
        self.spaceId = spaceId
        self.dataStore = dataStore
        self.owner = owner
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty compact toolbar gives the title bar the header's height and centers the traffic lights.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unifiedCompact
        window.contentMinSize = NSSize(width: 360, height: 240)
        window.backgroundColor = owner.frameColor(forSpace: spaceId)
        engine.applyPageBackgroundColor(window.backgroundColor.contentSurfaceColor)
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) { window.center() }

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
        header.field.delegate = self
        header.onCopy = { [weak self] in self?.copyCurrentURL(nil) }
        header.onOpenInSpace = { [weak self] in
            guard let self else { return }
            openInSpace(spaceId)
        }
        header.onShowSpaces = { [weak self] button in self?.showSpacesMenu(from: button) }
        header.openButton.title = String(format: "Open in %@".localized, spaceLabel(spaceId))
        observations = [
            engine.wkWebView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshAddress() } },
            engine.wkWebView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            engine.wkWebView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshProgress() } },
            engine.wkWebView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshProgress() } }
        ]
        refreshAddress()
        refreshTitle()
    }

    /// Shows the window, with the address field focused when there is no page yet.
    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(engine.currentURL == nil ? header.field : engine.wkWebView)
    }

    func openInSpace(_ targetSpaceId: UUID) {
        owner?.moveLittleWindow(self, toSpace: targetSpaceId)
    }

    /// File > Open as Tab: the "Open in <Space>" button's Space.
    @objc func openPageAsTab(_ sender: Any?) { openInSpace(spaceId) }

    /// Hands the engine over to a tab, which re-parents its view; the window then closes.
    func detachEngine() -> WKWebViewTab {
        isDetached = true
        engine.view.removeFromSuperview()
        return engine
    }

    private func spaceLabel(_ id: UUID) -> String {
        guard let space = owner?.context.spaceManager?.space(with: id) else { return "Space".localized }
        return "\(space.icon) \(space.name)"
    }

    private func showSpacesMenu(from button: NSButton) {
        let menu = NSMenu()
        let others = owner?.switchableSpaces.filter { $0.id != spaceId && !$0.isPrivate } ?? []
        for space in others {
            menu.addItem(String(format: "Open in %@".localized, "\(space.icon) \(space.name)")) { [weak self] in self?.openInSpace(space.id) }
        }
        if others.isEmpty { menu.addItem(withTitle: "No Other Spaces".localized, action: nil, keyEquivalent: "") }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    private func refreshAddress() {
        guard header.field.currentEditor() == nil else { return }
        header.field.stringValue = engine.currentURL?.absoluteString ?? ""
    }

    private func refreshTitle() {
        let title = engine.currentTitle ?? ""
        window.title = title.isEmpty ? (engine.currentURL?.host ?? "Little Window".localized) : title
    }

    private func refreshProgress() {
        let webView = engine.wkWebView
        // A load starts near zero: show a sliver at once so the line reads as started.
        header.progressBar.progress = webView.isLoading ? max(0.08, webView.estimatedProgress) : nil
    }

    /// A URL as typed (a scheme, or a dotted name without spaces), anything else a search.
    private func navigate(to input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let typed = URL(string: text)
        let url: URL? = if let scheme = typed?.scheme?.lowercased(), ["http", "https", "file", "about"].contains(scheme) {
            typed
        } else if !text.contains(" "), text.contains(".") || text.hasPrefix("localhost") {
            URL(string: "https://" + text)
        } else {
            URL(string: SearchQueryBridgeHandler.searchURL(for: text, settings: owner?.context.settingsStore))
        }
        guard let url else { return }
        engine.loadURL(url)
        window.makeFirstResponder(engine.wkWebView)
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            navigate(to: header.field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window.makeFirstResponder(engine.currentURL == nil ? nil : engine.wkWebView)
            refreshAddress()
            return true
        default:
            return false
        }
    }

    // MARK: - Menu actions (the window delegate is on the responder chain)

    /// Cmd+W closes the Little window, not a tab of the browser window behind it.
    @objc func closeCurrentTab(_ sender: Any?) { window.performClose(sender) }

    @objc func copyCurrentURL(_ sender: Any?) {
        guard let url = engine.currentURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func openLocation(_ sender: Any?) {
        window.makeFirstResponder(header.field)
    }

    @objc func reloadCurrentPage(_ sender: Any?) { engine.reload() }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isDetached || engine.pageRequestedClose || engine.tryClose()
    }

    func windowDidMove(_ notification: Notification) { window.saveFrame(usingName: Self.frameName) }
    func windowDidEndLiveResize(_ notification: Notification) { window.saveFrame(usingName: Self.frameName) }

    func windowWillClose(_ notification: Notification) {
        observations = []
        owner?.littleWindows[engine.id] = nil
        guard !isDetached else { return }
        isDetached = true
        if let context = owner?.context, !context.isTerminating, let url = engine.currentURL,
           ["http", "https", "file"].contains(url.scheme?.lowercased()) {
            context.recentlyClosed.push(.page(url), spaceId: spaceId, parentFolderId: nil, section: nil, sortOrder: nil)
        }
        // Deferred so the caller's stack unwinds before releasing the WKWebView.
        let engine = engine
        DispatchQueue.main.async { engine.teardown() }
    }
}

/// The Little window's bar, in the title bar past the traffic lights: the address field in a pill,
/// Copy URL, "Open in <Space>" with a menu of the other Spaces, and a load progress line.
@MainActor
private final class LittleWindowHeaderView: NSView {
    private static let trafficLightsWidth: CGFloat = 78
    private static let minimumAddressWidth: CGFloat = 120

    let field = NSTextField()
    let progressBar = PopupProgressBar()
    var onCopy: (() -> Void)?
    var onOpenInSpace: (() -> Void)?
    var onShowSpaces: ((NSButton) -> Void)?
    private let pill = PillView()
    private(set) lazy var openButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(openAction(_:)))
        button.bezelStyle = .accessoryBarAction
        button.lineBreakMode = .byTruncatingMiddle
        return button
    }()
    private lazy var spacesButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Other Spaces".localized) ?? NSImage(),
            target: self,
            action: #selector(spacesAction(_:))
        )
        button.isBordered = false
        button.toolTip = "Other Spaces".localized
        return button
    }()
    private lazy var copyButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "link", accessibilityDescription: "Copy URL".localized) ?? NSImage(),
            target: self,
            action: #selector(copyAction(_:))
        )
        button.isBordered = false
        button.toolTip = "Copy URL".localized
        return button
    }()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.placeholderString = "Search or enter address".localized
        pill.addSubview(field)
        addSubview(pill)
        addSubview(copyButton)
        addSubview(openButton)
        addSubview(spacesButton)
        addSubview(progressBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        var trailing = bounds.width - 8
        spacesButton.frame = NSRect(x: trailing - 20, y: (midY - 10).rounded(), width: 20, height: 20)
        trailing = spacesButton.frame.minX - 2
        let leading = Self.trafficLightsWidth
        // The Space name truncates before the address field loses its room.
        let openRoom = max(0, trailing - 6 - 28 - 6 - leading - Self.minimumAddressWidth)
        let openSize = NSSize(width: min(openButton.intrinsicContentSize.width, 200, openRoom), height: openButton.intrinsicContentSize.height)
        openButton.frame = NSRect(x: trailing - openSize.width, y: (midY - openSize.height / 2).rounded(), width: openSize.width, height: openSize.height)
        trailing = openButton.frame.minX - 6
        copyButton.frame = NSRect(x: trailing - 28, y: (midY - 14).rounded(), width: 28, height: 28)
        trailing = copyButton.frame.minX - 6
        pill.frame = NSRect(x: leading, y: (midY - 13).rounded(), width: max(0, trailing - leading), height: 26)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: 10, y: ((26 - fieldHeight) / 2).rounded(), width: max(0, pill.frame.width - 20), height: fieldHeight)
        progressBar.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
    }

    // Only the controls take clicks: the rest falls through to the traffic lights and the window drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton || hit?.isDescendant(of: field) == true ? hit : nil
    }

    @objc private func openAction(_ sender: Any?) { onOpenInSpace?() }
    @objc private func spacesAction(_ sender: NSButton) { onShowSpaces?(sender) }
    @objc private func copyAction(_ sender: Any?) { onCopy?() }
}
