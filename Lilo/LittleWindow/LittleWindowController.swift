import AppKit
import WebKit

/// A Little window: one page in a small window of its own, outside every Space's tab list. It opens on the
/// command bar, and a navigation turns it into a window with a strip (address, copy link, "Open in <Space>")
/// over the page. Its page runs in the profile of the Space it opened for; closing the window sends the page
/// to Recently Closed.
@MainActor
final class LittleWindowController: NSObject, NSWindowDelegate {
    enum Mode { case start, page }

    static let frameName = "LiloLittleWindow"
    static let startSize = NSSize(width: 512, height: 380)
    static let defaultSize = NSSize(width: 900, height: 640)
    /// The title bar's height with its empty unified toolbar: the strip sits in it, level with the traffic lights.
    static let stripHeight: CGFloat = 52
    private static let pageInset: CGFloat = 8
    private static let morphDuration: TimeInterval = 0.22

    let engine: WKWebViewTab
    /// "Open in" targets it, and the closed page reopens there.
    let spaceId: UUID
    /// A Space whose tabs run in another store gets the page reloaded rather than this live engine.
    let dataStore: WKEngineDataStore
    let window: LittlePanel
    /// The browser window whose delegate methods serve the page.
    weak var owner: MainWindowController?
    private(set) var mode = Mode.start
    let chromeHost = LittleChromeHost()
    let chromeView: OverlayWebView
    private let bridgeRouter: BridgeRouter
    private let pageContainer = NSView()
    private var observations: [NSKeyValueObservation] = []
    private(set) var isChromeReady = false
    /// Set once the engine leaves for a tab or is torn down, so it is never torn down twice.
    private var isDetached = false
    private var hasBeenKey = false

    init(engine: WKWebViewTab, spaceId: UUID, dataStore: WKEngineDataStore, owner: MainWindowController) {
        self.engine = engine
        self.spaceId = spaceId
        self.dataStore = dataStore
        self.owner = owner
        window = LittlePanel(contentRect: NSRect(origin: .zero, size: Self.startSize))
        chromeView = MainWindowController.makeChromeWebView(frame: .zero)
        bridgeRouter = BridgeRouter(chromeWebView: chromeView)
        super.init()
        window.backgroundColor = owner.frameColor(forSpace: spaceId)
        engine.applyPageBackgroundColor(window.backgroundColor.contentSurfaceColor)
        window.delegate = self
        window.title = "Little Window".localized
        window.shouldCloseOnEscape = { [weak self] in self?.escapeClosesWindow() ?? false }

        if let contentView = window.contentView {
            pageContainer.frame = NSRect(
                x: Self.pageInset, y: Self.pageInset,
                width: contentView.bounds.width - 2 * Self.pageInset,
                height: contentView.bounds.height - Self.stripHeight - Self.pageInset
            )
            pageContainer.autoresizingMask = [.width, .height]
            pageContainer.wantsLayer = true
            pageContainer.layer?.cornerRadius = 10
            pageContainer.layer?.masksToBounds = true
            pageContainer.isHidden = true
            engine.view.frame = pageContainer.bounds
            engine.view.autoresizingMask = [.width, .height]
            pageContainer.addSubview(engine.view)
            contentView.addSubview(pageContainer)

            chromeHost.frame = contentView.bounds
            chromeHost.autoresizingMask = [.width, .height]
            chromeView.frame = chromeHost.bounds
            chromeView.autoresizingMask = [.width, .height]
            chromeHost.addSubview(chromeView)
            contentView.addSubview(chromeHost)
        }

        chromeView.configuration.userContentController.add(bridgeRouter, name: "lilo")
        bridgeRouter.register(handler: LittleWindowBridgeHandler(little: self))
        bridgeRouter.register(handler: makeSearchHandler(owner: owner))
        observations = [
            engine.wkWebView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            engine.wkWebView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.sendState() } }
        ]
        refreshTitle()
    }

    private func makeSearchHandler(owner: MainWindowController) -> SearchBridgeHandler {
        let context = owner.context
        let profileId = context.spaceManager?.space(with: spaceId)?.profileId
        let profile = { profileId.flatMap { try? context.profileContexts.context(for: $0) } }
        return SearchBridgeHandler(
            historyStoreProvider: { profile()?.history },
            faviconStoreProvider: { profile()?.favicons },
            bridgeRouter: bridgeRouter,
            suggestionsEnabledProvider: { context.settingsStore?.searchSuggestions ?? true },
            preconnect: { [weak self] url in self?.engine.preconnect(to: url) },
            preloadTopHit: { _ in }
        )
    }

    // MARK: - Showing

    /// Shows the window: on the command bar, or on `inPage` the page that is loading in it. From a shortcut the app is
    /// brought forward first, so the bar's field takes the keyboard.
    func show(inPage: Bool? = nil) {
        let showsPage = inPage ?? (engine.currentURL != nil)
        mode = showsPage ? .page : .start
        applyMode()
        if showsPage {
            if !window.setFrameUsingName(Self.frameName) { window.setFrame(window.frame.withSize(Self.defaultSize), display: false); window.center() }
        } else {
            window.setFrame(startFrame(), display: false)
        }
        chromeView.load(URLRequest(url: littleChromeURL()))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(showsPage ? engine.wkWebView : chromeView)
    }

    private func littleChromeURL() -> URL {
        let base = owner?.chromeUIDevServerURL() ?? ChromeUISchemeHandler.indexURL
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.query = "little"
        return components?.url ?? base
    }

    /// Centered on the screen under the pointer, in its upper part where a search box is looked for.
    private func startFrame() -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: Self.defaultSize)
        let size = Self.startSize
        return NSRect(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.2 - size.height, width: size.width, height: size.height)
    }

    /// The page's window: its remembered size, from the start card's top center.
    private func pageFrame(from start: NSRect) -> NSRect {
        let size = savedPageSize() ?? Self.defaultSize
        let visible = window.screen?.visibleFrame ?? start
        var frame = NSRect(x: start.midX - size.width / 2, y: start.maxY - size.height, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        return frame
    }

    private func savedPageSize() -> NSSize? {
        guard let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") else { return nil }
        let numbers = saved.split(separator: " ").prefix(4).compactMap { Double($0) }
        return numbers.count == 4 && numbers[2] > 0 && numbers[3] > 0 ? NSSize(width: numbers[2], height: numbers[3]) : nil
    }

    private func applyMode() {
        let isStart = mode == .start
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = isStart
        }
        window.level = isStart ? .floating : .normal
        window.contentMinSize = isStart ? Self.startSize : NSSize(width: 360, height: 240)
        window.contentMaxSize = isStart ? Self.startSize : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        pageContainer.isHidden = isStart
    }

    /// A navigation started in the start card: the window grows into the page's.
    private func showPage() {
        guard mode == .start else { return }
        mode = .page
        applyMode()
        let frame = pageFrame(from: window.frame)
        // The contents resize with the window; the page shows in the same turn, under the strip.
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        window.makeFirstResponder(engine.wkWebView)
        sendState()
    }

    // MARK: - Chrome

    func chromeDidLoad() {
        isChromeReady = true
        sendState()
    }

    /// The whole of what the chrome shows, sent whenever it changes: a mode, an address, a load.
    func sendState() {
        guard isChromeReady, let owner, let space = owner.context.spaceManager?.space(with: spaceId) else { return }
        let agentsSpaceIds = owner.context.settingsStore?.agentsSpaceIds ?? []
        let others = owner.switchableSpaces.filter { $0.id != spaceId && !$0.isPrivate }.map { other in
            ["id": other.id.uuidString, "name": other.name, "icon": agentsSpaceIds.contains(other.id) ? "" : other.icon]
        }
        bridgeRouter.send(event: "littleState", data: [
            "mode": mode == .page ? "page" : "start",
            "url": engine.currentURL?.absoluteString ?? "",
            "loading": engine.wkWebView.isLoading,
            "space": ["id": space.id.uuidString, "name": space.name, "icon": space.icon, "color": space.color],
            "otherSpaces": others,
            "leadingInset": trafficLightsInset()
        ])
    }

    func sendSharedSettings(_ keys: [String]) {
        guard let settings = owner?.context.settingsStore?.allSettings() else { return }
        bridgeRouter.send(event: "settingsLoaded", data: ["settings": settings.filter { keys.contains($0.key) }])
    }

    /// Where the strip starts: past the zoom button, wherever AppKit puts it.
    private func trafficLightsInset() -> CGFloat {
        guard let zoom = window.standardWindowButton(.zoomButton) else { return 78 }
        return zoom.convert(zoom.bounds, to: nil).maxX + 12
    }

    func startWindowDrag() {
        guard let event = chromeView.lastMouseDownEvent else { return }
        window.performDrag(with: event)
    }

    /// The engine's delegate calls it when the page's address changes: a navigation the page starts shows its
    /// address once it commits, when the web view's own URL no longer changes.
    func refreshAddress() {
        sendState()
    }

    private func refreshTitle() {
        let title = engine.currentTitle ?? ""
        window.title = title.isEmpty ? (engine.currentURL?.host ?? "Little Window".localized) : title
    }

    // MARK: - Actions

    /// Loads a page from the command bar: web pages and local files only.
    func navigate(to url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return }
        engine.loadURL(url)
        showPage()
    }

    func focusPage() {
        if mode == .page { window.makeFirstResponder(engine.wkWebView) }
    }

    func openInSpace(_ targetSpaceId: UUID) {
        owner?.moveLittleWindow(self, toSpace: targetSpaceId)
    }

    /// A page that is not loaded yet goes straight to its tab.
    func openAsTab(_ url: URL) {
        owner?.openLittleWindowURLAsTab(url, from: self)
    }

    /// File > Open as Tab: the "Open in <Space>" button's Space.
    @objc func openPageAsTab(_ sender: Any?) { openInSpace(spaceId) }

    /// Hands the engine over to a tab, which re-parents its view; the window then closes.
    func detachEngine() -> WKWebViewTab {
        isDetached = true
        engine.view.removeFromSuperview()
        return engine
    }

    /// Whether Escape closes the window instead of reaching what has the keyboard: the page does not keep it,
    /// the chrome (its command bar, its menu) takes its own first.
    private func escapeClosesWindow() -> Bool {
        guard isChromeReady, mode == .page, let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: engine.wkWebView) else { return !isChromeReady }
        return (responder as? NSTextInputClient)?.hasMarkedText() != true
    }

    // MARK: - Menu actions (the window delegate is on the responder chain)

    /// Cmd+W closes the Little window, not a tab of the browser window behind it.
    @objc func closeCurrentTab(_ sender: Any?) { window.performClose(sender) }

    @objc func copyCurrentURL(_ sender: Any?) {
        guard let url = engine.currentURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Cmd+L: the command bar, over the page with its address selected.
    @objc func openLocation(_ sender: Any?) {
        window.makeFirstResponder(chromeView)
        bridgeRouter.send(event: "toggleCommandBar", data: ["prefill": engine.currentURL?.absoluteString ?? "", "selectAll": true])
    }

    @objc func reloadCurrentPage(_ sender: Any?) { engine.reload() }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isDetached || engine.pageRequestedClose || engine.tryClose()
    }

    func windowDidBecomeKey(_ notification: Notification) { hasBeenKey = true }

    /// The start card is Spotlight-like: it goes when the user clicks away. A page's window stays.
    func windowDidResignKey(_ notification: Notification) {
        guard mode == .start, hasBeenKey, isChromeReady, window.attachedSheet == nil else { return }
        window.close()
    }

    func windowDidMove(_ notification: Notification) { savePageFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { savePageFrame() }

    private func savePageFrame() {
        if mode == .page, window.isVisible { window.saveFrame(usingName: Self.frameName) }
    }

    func windowWillClose(_ notification: Notification) {
        observations = []
        chromeView.configuration.userContentController.removeScriptMessageHandler(forName: "lilo")
        // Whatever still holds this controller, the chrome page and its WebContent process end with the window.
        let close = NSSelectorFromString("_close")
        if chromeView.responds(to: close) { unsafe chromeView.perform(close) }
        owner?.littleWindows[engine.id] = nil
        guard !isDetached else { return }
        isDetached = true
        if let context = owner?.context, !context.isTerminating, let url = engine.currentURL,
           ["http", "https", "file"].contains(url.scheme?.lowercased()) {
            context.recentlyClosed.push(.page(url, title: engine.currentTitle), spaceId: spaceId, parentFolderId: nil, section: nil, sortOrder: nil)
        }
        // Deferred so the caller's stack unwinds before releasing the WKWebView.
        let engine = engine
        DispatchQueue.main.async { engine.teardown() }
    }
}

private extension NSRect {
    func withSize(_ size: NSSize) -> NSRect { NSRect(origin: origin, size: size) }
}
