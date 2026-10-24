import AppKit
import WebKit

/// A window's `chrome.sidePanel`, docked right of the content. One panel at a time, following the active tab: an extension-wide panel
/// stays across switches, a tab-specific one is remembered by its tab. Only the shown panel has a web view, so a hidden one reloads.
@MainActor
final class SidePanelController: NSObject {
    struct Entry: Hashable {
        let extensionId: String
        /// Nil for the extension-wide panel.
        let tabId: UUID?
    }

    /// Chrome's default and minimum width; one width, the user's last, serves every extension panel.
    static let minimumWidth: CGFloat = 360
    private static let widthKey = "sidePanel.width"
    private static let minimumContentWidth: CGFloat = 200

    private unowned let window: MainWindowController
    /// The profile registry of the panels, the window's when the first one opened.
    private weak var registry: ProfileExtensionRegistry?
    /// The extension-wide panel open in the window, and the tab-specific panel open in each tab.
    private var globalEntry: String?
    private var tabEntries: [UUID: String] = [:]
    /// Entries `onOpened` went out for, with the URL their `onClosed` names.
    private var announced: [Entry: URL] = [:]
    private(set) var shown: Entry?
    private var panel: SidePanelView?
    private var loadObservation: NSKeyValueObservation?
    private lazy var divider = makeDivider()
    private var width = max(CGFloat(UserDefaults.lilo.double(forKey: SidePanelController.widthKey)), SidePanelController.minimumWidth)

    init(window: MainWindowController) {
        self.window = window
    }

    var webView: WKWebView? { panel?.engine.wkWebView }
    var engineId: UUID? { panel?.engine.id }

    /// What the content area leaves on its right for the panel and its divider.
    var reservedWidth: CGFloat { panel.map { $0.frame.width + SplitDividerView.width } ?? 0 }

    private var panelWidth: CGFloat {
        guard let bounds = window.window?.contentView?.bounds else { return width }
        let available = bounds.width - window.sidebarWidth - MainWindowController.contentInset * 2
        return max(0, min(width, available - Self.minimumContentWidth - SplitDividerView.width))
    }

    private var handler: SidePanelBridgeHandler { window.context.engineFactory.sidePanelHandler }
    private var activeTabId: UUID? { window.tabManager.activeOpenTabId }

    // MARK: - Requests

    /// `sidePanel.open` and the toolbar action. A tab-specific panel opens in its tab, at once when that
    /// tab is active; an extension-wide one replaces the window's, but leaves a tab-specific panel in
    /// the active tab on screen unless the call named that tab.
    func open(_ extensionId: String, tabSpecific: Bool, in tabId: UUID?) {
        adoptRegistry()
        let active = activeTabId
        if tabSpecific, let tabId {
            setTabEntry(tabId, extensionId)
            if tabId == active { show(Entry(extensionId: extensionId, tabId: tabId), replacing: true) }
            return
        }
        if let tabId, tabId != active { setTabEntry(tabId, nil) }
        setGlobalEntry(extensionId)
        if shown?.tabId != nil, tabId != active { return }
        show(Entry(extensionId: extensionId, tabId: nil), replacing: true)
    }

    /// `sidePanel.close`: only the extension's own panel, for the tab or the window named.
    func close(_ extensionId: String, tabId: UUID?) {
        if let tabId {
            guard tabEntries[tabId] == extensionId else { return }
            if shown == Entry(extensionId: extensionId, tabId: tabId) { closePanel() } else { setTabEntry(tabId, nil) }
        } else if shown == Entry(extensionId: extensionId, tabId: nil) {
            closePanel()
        } else if globalEntry == extensionId {
            setGlobalEntry(nil)
        }
    }

    func toggle(_ extensionId: String, tabSpecific: Bool) {
        if shown?.extensionId == extensionId { closePanel() } else { open(extensionId, tabSpecific: tabSpecific, in: activeTabId) }
    }

    /// The header's close button, `window.close()` in the panel and a toolbar toggle: as in Chrome the
    /// window's extension-wide panel and the active tab's own panel close; other tabs keep theirs.
    func closePanel() {
        if let active = activeTabId { setTabEntry(active, nil) }
        setGlobalEntry(nil)
        show(nil, replacing: true)
    }

    // MARK: - Window events

    /// Picks the panel for the newly active tab, in Chrome's order: the tab's own open panel, then
    /// (while one shows) the shown extension's panel, then the window's extension-wide one.
    func activeTabDidChange() {
        guard registry != nil else { return }
        guard registry === window.profileContext?.extensions else { return closeAll() }
        for tabId in tabEntries.keys where window.context.browserState.owningSpaceId(forTab: tabId) == nil {
            setTabEntry(tabId, nil)
        }
        guard let active = activeTabId else { return }
        if let extensionId = tabEntries[active] {
            return show(Entry(extensionId: extensionId, tabId: active), replacing: false)
        }
        guard let shown else { return }
        let next = [shown.extensionId, globalEntry].lazy.compactMap { $0 }.first { self.url(of: Entry(extensionId: $0, tabId: nil)) != nil }
        guard let next else {
            setGlobalEntry(nil)
            return show(nil, replacing: false)
        }
        let tabSpecific = Entry(extensionId: next, tabId: active)
        show(url(of: tabSpecific) != nil ? tabSpecific : Entry(extensionId: next, tabId: nil), replacing: false)
    }

    /// The extension's options changed: a panel they no longer enable closes, the shown one with the
    /// whole panel, and the shown one loads its new path in place.
    func optionsDidChange(of extensionId: String) {
        guard registry != nil else { return }
        if let shown, shown.extensionId == extensionId, url(of: shown) == nil { return closePanel() }
        if globalEntry == extensionId, url(of: Entry(extensionId: extensionId, tabId: nil)) == nil { setGlobalEntry(nil) }
        for (tabId, id) in tabEntries where id == extensionId && url(of: Entry(extensionId: id, tabId: tabId)) == nil {
            setTabEntry(tabId, nil)
        }
        if let shown, shown.extensionId == extensionId, let url = url(of: shown), let panel, panel.url != url {
            panel.load(url)
        }
    }

    func tabWillClose(_ tabId: UUID) {
        setTabEntry(tabId, nil)
    }

    /// The extension's pages are gone with it: its panels close without events.
    func extensionDidUnload(_ extensionId: String) {
        announced = announced.filter { $0.key.extensionId != extensionId }
        if globalEntry == extensionId { globalEntry = nil }
        tabEntries = tabEntries.filter { $0.value != extensionId }
        if shown?.extensionId == extensionId { show(nil, replacing: false) }
    }

    /// The window closes or shows another profile: every panel closes, each with its `onClosed`.
    func closeAll() {
        globalEntry = nil
        tabEntries = [:]
        for entry in announced.keys { retire(entry) }
        show(nil, replacing: false)
        registry = nil
    }

    func setFrameColor(_ color: NSColor) {
        divider.setFrameColor(color, animated: true)
        guard let panel else { return }
        let surface = color.contentSurfaceColor
        panel.layer?.backgroundColor = surface.cgColor
        panel.engine.applyPageBackgroundColor(surface)
    }

    // MARK: - State

    private func adoptRegistry() {
        let current = window.profileContext?.extensions
        if registry !== current { closeAll() }
        registry = current
    }

    private func url(of entry: Entry) -> URL? {
        registry.flatMap { handler.panelURL(entry.extensionId, tabId: entry.tabId, registry: $0) }
    }

    private func setTabEntry(_ tabId: UUID, _ extensionId: String?) {
        let previous = tabEntries[tabId]
        guard previous != extensionId else { return }
        tabEntries[tabId] = extensionId
        previous.map { retire(Entry(extensionId: $0, tabId: tabId)) }
    }

    private func setGlobalEntry(_ extensionId: String?) {
        guard globalEntry != extensionId else { return }
        let previous = globalEntry
        globalEntry = extensionId
        previous.map { retire(Entry(extensionId: $0, tabId: nil)) }
    }

    /// Puts `next` on screen, active in its scope. A tab switch keeps the entry it hides open for
    /// later; any other change closes it (`replacing`), as Chrome reports a replaced panel closed.
    private func show(_ next: Entry?, replacing: Bool) {
        if let next {
            if let active = activeTabId { setTabEntry(active, next.tabId == nil ? nil : next.extensionId) }
            if next.tabId == nil { setGlobalEntry(next.extensionId) }
        }
        guard next != shown else { return }
        if replacing, let shown { retire(shown) }
        shown = next
        loadObservation = nil
        panel?.engine.teardown()
        panel?.removeFromSuperview()
        panel = nil
        if let next, let registry, let context = registry.context(for: next.extensionId), let url = url(of: next) {
            present(next, url: url, context: context)
        } else {
            shown = nil
            divider.removeFromSuperview()
        }
        window.updateContentContainerFrame(animated: false)
        window.bridgeRouter?.send(event: "sidePanelWidthChanged", data: ["width": reservedWidth])
    }

    private func present(_ entry: Entry, url: URL, context: WKWebExtensionContext) {
        guard let contentView = window.window?.contentView else { return }
        let engine = WKWebViewTab(webView: WKWebView(frame: .zero, configuration: context.webViewConfiguration ?? WKWebViewConfiguration()))
        window.configureEngineIfNeeded(engine)
        engine.applyPageBackgroundColor(window.currentContentSurfaceColor)
        let panel = SidePanelView(
            engine: engine,
            title: context.webExtension.displayName ?? "",
            icon: context.webExtension.icon(for: CGSize(width: 16, height: 16)),
            background: window.currentContentSurfaceColor
        )
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.autoresizingMask = [.minXMargin, .height]
        divider.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(panel, positioned: .above, relativeTo: window.contentContainerView)
        contentView.addSubview(divider, positioned: .above, relativeTo: panel)
        self.panel = panel
        layoutPanel()
        // `onOpened` waits for the first load, so `runtime.getContexts` in its listener lists the panel.
        if announced[entry] == nil {
            loadObservation = engine.wkWebView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard change.newValue == false else { return }
                MainActor.assumeIsolated {
                    guard let self, self.shown == entry, self.announced[entry] == nil else { return }
                    self.loadObservation = nil
                    let loaded = self.panel?.url ?? url
                    self.announced[entry] = loaded
                    self.emit("onOpened", entry, url: loaded)
                }
            }
        }
        panel.load(url)
    }

    /// Fits the panel to the room the window and the sidebar leave it, and tells the chrome when its width changes.
    func fitToWindow() {
        let reserved = reservedWidth
        layoutPanel()
        if reservedWidth != reserved { window.bridgeRouter?.send(event: "sidePanelWidthChanged", data: ["width": reservedWidth]) }
    }

    private func layoutPanel() {
        guard let panel, let bounds = window.window?.contentView?.bounds else { return }
        let inset = MainWindowController.contentInset
        let width = panelWidth
        panel.frame = NSRect(x: bounds.maxX - inset - width, y: inset, width: width, height: bounds.height - inset * 2)
        divider.frame = NSRect(x: panel.frame.minX - SplitDividerView.width, y: inset, width: SplitDividerView.width, height: panel.frame.height)
    }

    private func retire(_ entry: Entry) {
        guard let url = announced.removeValue(forKey: entry) else { return }
        emit("onClosed", entry, url: url)
    }

    /// Native knows windows and tabs by their place in WebKit's lists; JS turns those into ids.
    private func emit(_ event: String, _ entry: Entry, url: URL) {
        guard let registry else { return }
        var info: [String: Any] = ["windowPosition": window.window.flatMap { registry.windowPosition(of: $0) } ?? -1, "path": url.path]
        if let tabId = entry.tabId, let adapter = window.tabManager.tabAdapter(for: tabId) {
            info["index"] = registry.tabPosition(of: adapter, extensionId: entry.extensionId)?["index"]
        }
        registry.gapEvents.emit("sidePanel", event, args: [info], to: [entry.extensionId])
    }

    // MARK: - Resizing

    private func makeDivider() -> SplitDividerView {
        let divider = SplitDividerView()
        divider.setFrameColor(window.window?.backgroundColor ?? MainWindowController.defaultSidebarBackgroundColor(), animated: false)
        divider.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        divider.onSuperviewResize = { [weak self] in
            self?.fitToWindow()
            self?.window.updateContentContainerFrame(animated: false)
        }
        divider.onDrag = { [weak self] point in
            guard let self, let bounds = window.window?.contentView?.bounds else { return }
            width = max(Self.minimumWidth, bounds.maxX - MainWindowController.contentInset - point.x - SplitDividerView.width / 2)
            layoutPanel()
            window.updateContentContainerFrame(animated: false)
        }
        divider.onDragEnd = { [weak self] in
            guard let self else { return }
            width = max(Self.minimumWidth, panelWidth)
            UserDefaults.lilo.set(Double(width), forKey: Self.widthKey)
            window.bridgeRouter?.send(event: "sidePanelWidthChanged", data: ["width": reservedWidth])
        }
        return divider
    }

    @objc func mouseEntered(with event: NSEvent) { divider.setHovered(true) }
    @objc func mouseExited(with event: NSEvent) { divider.setHovered(false) }
    @objc func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
}

/// The side panel: a header with the extension's icon, name and a close button, above its page.
@MainActor
final class SidePanelView: NSView {
    private static let headerHeight: CGFloat = 36

    let engine: WKWebViewTab
    var onClose: (() -> Void)?
    private let header = NSView()
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let closeButton: NSButton

    var url: URL? { engine.wkWebView.url }

    init(engine: WKWebViewTab, title: String, icon: NSImage?, background: NSColor) {
        self.engine = engine
        titleField = NSTextField(labelWithString: title)
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close".localized) ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        iconView.image = icon
        // The extension's name follows it.
        iconView.setAccessibilityElement(false)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        closeButton.isBordered = false
        closeButton.toolTip = "Close".localized
        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))
        [iconView, titleField, closeButton].forEach(header.addSubview)
        addSubview(header)
        addSubview(engine.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func load(_ url: URL) {
        engine.loadURL(url)
    }

    override func layout() {
        super.layout()
        let height = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        iconView.frame = NSRect(x: 12, y: (height - 16) / 2, width: 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 34, y: (height - 26) / 2, width: 26, height: 26)
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(x: iconView.frame.maxX + 8, y: ((height - titleHeight) / 2).rounded(), width: max(0, closeButton.frame.minX - iconView.frame.maxX - 16), height: titleHeight)
        engine.view.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    }

    @objc private func closeAction(_ sender: Any?) { onClose?() }
}
