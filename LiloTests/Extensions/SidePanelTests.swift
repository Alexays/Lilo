import AppKit
import WebKit
import XCTest
@testable import Lilo

/// `chrome.sidePanel` as in Chrome: the panel docks in the browser window beside the content, one at
/// a time, and follows the active tab between the extension-wide panel and tab-specific ones.
@MainActor
final class SidePanelTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var tempDir: URL!
    private var window: MainWindowController!
    private var registry: ProfileExtensionRegistry!
    private var router: GapBridgeRouter!
    private var extensionId: String!
    /// The window's two tabs: `first` is active at the start.
    private var first: UUID!
    private var second: UUID!
    private var savedWidth: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedWidth = UserDefaults.lilo.object(forKey: "sidePanel.width")
        UserDefaults.lilo.removeObject(forKey: "sidePanel.width")
        browserContext = try await TemporaryBrowserContext()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        registry = try context.profileContexts.context(for: profileId).extensions
        extensionId = try await install("Panel")

        window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        window.window?.setContentSize(NSSize(width: 1200, height: 800))
        let contentView = try XCTUnwrap(window.window?.contentView)
        window.contentContainerView = NSView(frame: window.contentFrameRect())
        contentView.addSubview(window.contentContainerView)
        context.windows.add(window)
        window.switchToSpace(space.id)
        first = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"))?.id)
        second = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"), activate: false)?.id)
        window.activateTabStateFirst(id: first)
        router = context.engineFactory.gapRouter
    }

    override func tearDown() async throws {
        window.sidePanel.closeAll()
        browserContext.tearDown()
        browserContext = nil
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.lilo.set(savedWidth, forKey: "sidePanel.width")
        try await super.tearDown()
    }

    private func install(_ name: String) async throws -> String {
        let dir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"\#(name)","version":"1.0","permissions":["sidePanel"],"side_panel":{"default_path":"panel.html"}}"#
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        for page in ["panel", "tab", "other"] {
            try "<title>\(page)</title>".write(to: dir.appendingPathComponent("\(page).html"), atomically: true, encoding: .utf8)
        }
        try #"""
        chrome.sidePanel.onOpened.addListener((info) => { document.title = 'opened ' + JSON.stringify(info); });
        chrome.sidePanel.onClosed.addListener((info) => { document.title = 'closed ' + JSON.stringify(info); });
        """#.write(to: dir.appendingPathComponent("listener.js"), atomically: true, encoding: .utf8)
        try #"<title>listening</title><script src="listener.js"></script>"#.write(to: dir.appendingPathComponent("listener.html"), atomically: true, encoding: .utf8)
        let before = Set(registry.loadedExtensions.map(\.id))
        try await registry.load(from: dir)
        return try XCTUnwrap(registry.loadedExtensions.map(\.id).first { !before.contains($0) })
    }

    @discardableResult
    private func call(_ method: String, _ params: [String: Any] = [:], from id: String? = nil) async -> (result: Any?, error: String?) {
        await router.route(namespace: "sidePanel", method: method, params: params, extensionId: id ?? extensionId, fromWorker: true, registry: registry)
    }

    /// What JS sends for `{tabId}`: the tab's position beside its WebKit id.
    private func tab(_ tabId: UUID, webKitId: Int = 1) throws -> [String: Any] {
        let adapter = try XCTUnwrap(window.tabManager.tabAdapter(for: tabId))
        return ["tabId": webKitId, "tab": try XCTUnwrap(registry.tabPosition(of: adapter, extensionId: extensionId))]
    }

    private var thisWindow: [String: Any] {
        ["windowId": 1, "windowPosition": window.tabManager.windowAdapter.flatMap { registry.windowPosition(of: $0, extensionId: extensionId) } ?? -1]
    }

    private func gesture(_ params: [String: Any]) -> [String: Any] {
        params.merging(["userGesture": true]) { $1 }
    }

    private func panelLoads(_ page: String) async -> Bool {
        await pollUntil { self.window.sidePanel.webView?.url?.lastPathComponent == "\(page).html" && self.window.sidePanel.webView?.isLoading == false }
    }

    private var panelView: SidePanelView? {
        window.window?.contentView?.subviews.lazy.compactMap { $0 as? SidePanelView }.first
    }

    // MARK: - Docking

    func testThePanelDocksRightOfTheContentWhichShrinks() async throws {
        let fullWidth = window.contentFrameRect().width

        let (_, error) = await call("open", gesture(thisWindow))

        XCTAssertNil(error)
        let loaded = await panelLoads("panel")
        XCTAssertTrue(loaded)
        let panel = try XCTUnwrap(panelView)
        XCTAssertEqual(panel.frame.width, SidePanelController.minimumWidth, "Chrome's default width")
        XCTAssertEqual(window.contentFrameRect().width, fullWidth - SidePanelController.minimumWidth - SplitDividerView.width)
        XCTAssertEqual(panel.frame.maxX, try XCTUnwrap(window.window?.contentView).bounds.maxX - MainWindowController.contentInset)
        XCTAssertNil(registry.tabPosition(of: try XCTUnwrap(window.sidePanel.webView), extensionId: extensionId), "a side panel is not a tab")
    }

    func testThePanelTakesTheNewSpaceColor() async throws {
        await call("open", gesture(thisWindow))
        let panel = try XCTUnwrap(panelView)
        window.contentContainerView.wantsLayer = true

        window.applyWindowChromeColors("#841b23")

        let surface = window.currentContentSurfaceColor.cssHexString
        XCTAssertEqual(panel.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.cssHexString, surface, "the header band")
        let tabPage = try XCTUnwrap(window.tabManager.activeEngineTab).wkWebView.underPageBackgroundColor
        XCTAssertEqual(panel.engine.wkWebView.underPageBackgroundColor, tabPage, "under the page, as under the tab's")
    }

    func testAShrinkingWindowNarrowsThePanelInsteadOfCoveringTheSidebar() async throws {
        await call("open", gesture(thisWindow))
        let panel = try XCTUnwrap(panelView)

        window.window?.setContentSize(NSSize(width: 600, height: 400))

        let content = window.contentFrameRect()
        XCTAssertGreaterThanOrEqual(content.width, 200, "the content keeps room")
        XCTAssertEqual(window.contentContainerView.frame, content)
        XCTAssertEqual(panel.frame.minX, content.maxX + SplitDividerView.width, "beside the content, clear of the sidebar")
        XCTAssertEqual(panel.frame.maxX, 600 - MainWindowController.contentInset)

        window.window?.setContentSize(NSSize(width: 1200, height: 800))
        XCTAssertEqual(panel.frame.width, SidePanelController.minimumWidth, "back to its width once there is room")
    }

    func testShowingTheSidebarNarrowsThePanel() async throws {
        window.toggleSidebar()
        window.window?.setContentSize(NSSize(width: 800, height: 600))
        await call("open", gesture(thisWindow))
        let panel = try XCTUnwrap(panelView)
        XCTAssertEqual(panel.frame.width, SidePanelController.minimumWidth)

        window.toggleSidebar()

        XCTAssertGreaterThanOrEqual(window.contentFrameRect().width, 200, "the content keeps room")
        XCTAssertEqual(panel.frame.minX, window.contentFrameRect().maxX + SplitDividerView.width)
    }

    func testThePanelIsListedAsASidePanelContext() async throws {
        await call("open", gesture(thisWindow))
        let loaded = await panelLoads("panel")
        XCTAssertTrue(loaded)

        let (views, error) = await router.route(
            namespace: "runtime", method: "extensionViews", params: [:], extensionId: extensionId, fromWorker: true, registry: registry
        )

        XCTAssertNil(error)
        let url = try XCTUnwrap(window.sidePanel.webView?.url)
        XCTAssertEqual(views as? [[String: String]], [["contextType": "SIDE_PANEL", "url": url.absoluteString]])
    }

    func testTheUserResizesThePanelAndTheWidthIsRemembered() async throws {
        await call("open", gesture(thisWindow))
        let divider = try XCTUnwrap(window.window?.contentView?.subviews.lazy.compactMap { $0 as? SplitDividerView }.first)
        let bounds = try XCTUnwrap(window.window?.contentView).bounds

        divider.onDrag?(NSPoint(x: bounds.maxX - MainWindowController.contentInset - 500 - SplitDividerView.width / 2, y: 100))
        divider.onDragEnd?()
        XCTAssertEqual(panelView?.frame.width, 500)
        divider.onDrag?(NSPoint(x: bounds.maxX - 100, y: 100))
        divider.onDragEnd?()
        XCTAssertEqual(panelView?.frame.width, SidePanelController.minimumWidth, "never narrower than Chrome's minimum")
        divider.onDrag?(NSPoint(x: bounds.maxX - MainWindowController.contentInset - 420 - SplitDividerView.width / 2, y: 100))
        divider.onDragEnd?()

        window.sidePanel.closePanel()
        XCTAssertNil(panelView)
        await call("open", gesture(thisWindow))
        XCTAssertEqual(panelView?.frame.width, 420, "every extension panel opens at the last width")
        XCTAssertEqual(UserDefaults.lilo.double(forKey: "sidePanel.width"), 420)
    }

    func testTheHeaderAndWindowCloseCloseThePanel() async throws {
        await call("open", gesture(thisWindow))
        let fullWidth = window.contentFrameRect().width + SidePanelController.minimumWidth + SplitDividerView.width
        try XCTUnwrap(panelView).onClose?()

        XCTAssertNil(window.sidePanel.shown)
        XCTAssertNil(panelView)
        XCTAssertEqual(window.contentFrameRect().width, fullWidth, "the content takes the room back")

        await call("open", gesture(thisWindow))
        window.tabDidRequestClose(try XCTUnwrap(panelView).engine)
        XCTAssertNil(window.sidePanel.shown, "window.close() in the panel closes it")
    }

    func testTheHeaderIconLeavesVoiceOverToTheExtensionsName() async throws {
        await call("open", gesture(thisWindow))
        let icon = try XCTUnwrap(panelView?.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }.first)
        XCTAssertFalse(icon.isAccessibilityElement())
    }

    func testOpeningAnotherExtensionsPanelReplacesIt() async throws {
        let otherId = try await install("Other")
        await call("open", gesture(thisWindow))

        let (_, error) = await call("open", gesture(thisWindow), from: otherId)

        XCTAssertNil(error)
        XCTAssertEqual(window.sidePanel.shown, .init(extensionId: otherId, tabId: nil))
        XCTAssertEqual(window.window?.contentView?.subviews.filter { $0 is SidePanelView }.count, 1, "one panel per window")
    }

    // MARK: - Following the active tab

    func testTheExtensionWidePanelStaysAcrossTabSwitches() async throws {
        await call("open", gesture(thisWindow))
        let loaded = await panelLoads("panel")
        XCTAssertTrue(loaded)
        let webView = window.sidePanel.webView

        window.activateTabStateFirst(id: second)

        XCTAssertEqual(window.tabManager.activeOpenTabId, second)
        XCTAssertTrue(window.sidePanel.webView === webView, "the same page, not reloaded")
    }

    func testATabSpecificPanelShowsOnlyInItsTabAndComesBack() async throws {
        await call("setOptions", ["enabled": false])
        await call("setOptions", try tab(first).merging(["path": "tab.html"]) { $1 })
        await call("open", gesture(try tab(first)))
        let loaded = await panelLoads("tab")
        XCTAssertTrue(loaded)
        XCTAssertEqual(window.sidePanel.shown, .init(extensionId: extensionId, tabId: first))

        window.activateTabStateFirst(id: second)
        XCTAssertNil(window.sidePanel.shown, "no extension-wide panel is open")
        XCTAssertNil(window.sidePanel.webView, "a hidden panel's page is released")

        window.activateTabStateFirst(id: first)
        XCTAssertEqual(window.sidePanel.shown, .init(extensionId: extensionId, tabId: first))
        let reloaded = await panelLoads("tab")
        XCTAssertTrue(reloaded)
    }

    func testTabsWithTheirOwnOptionsShowTheirOwnPanel() async throws {
        await call("setOptions", try tab(second).merging(["path": "other.html"]) { $1 })
        await call("open", gesture(thisWindow))

        window.activateTabStateFirst(id: second)
        XCTAssertEqual(window.sidePanel.shown, .init(extensionId: extensionId, tabId: second))
        let loaded = await panelLoads("other")
        XCTAssertTrue(loaded)

        window.activateTabStateFirst(id: first)
        XCTAssertEqual(window.sidePanel.shown, .init(extensionId: extensionId, tabId: nil), "tabs without options show the extension-wide panel")
    }

    func testADisabledTabStillShowsTheExtensionWidePanelButCannotOpenIts() async throws {
        await call("setOptions", try tab(second).merging(["enabled": false]) { $1 })
        await call("open", gesture(thisWindow))

        window.activateTabStateFirst(id: second)
        XCTAssertEqual(window.sidePanel.shown, .init(extensionId: extensionId, tabId: nil), "as Chrome's side panel UI does")
        let (_, error) = await call("open", gesture(try tab(second, webKitId: 9)))
        XCTAssertEqual(error, "No active side panel for tabId: 9")
    }

    // MARK: - Options

    func testSetOptionsNavigatesTheShownPanelOrClosesIt() async throws {
        await call("open", gesture(thisWindow))
        let loaded = await panelLoads("panel")
        XCTAssertTrue(loaded)
        let webView = window.sidePanel.webView

        await call("setOptions", ["path": "other.html"])
        let navigated = await panelLoads("other")
        XCTAssertTrue(navigated)
        XCTAssertTrue(window.sidePanel.webView === webView, "a new path loads in place")

        await call("setOptions", ["enabled": false])
        XCTAssertNil(window.sidePanel.shown)
        let (_, error) = await call("open", gesture(thisWindow))
        XCTAssertEqual(error, "No active side panel for windowId: 1")
    }

    func testGetOptionsFallsBackFromTheTabToTheExtensionToTheManifest() async throws {
        let manifest = await call("getOptions").result as? [String: Any]
        XCTAssertEqual(manifest?["path"] as? String, "panel.html")
        XCTAssertEqual(manifest?["enabled"] as? Bool, true)

        await call("setOptions", ["path": "other.html"])
        await call("setOptions", try tab(first, webKitId: 4).merging(["enabled": false]) { $1 })

        let global = await call("getOptions", try tab(second)).result as? [String: Any]
        XCTAssertEqual(global?["path"] as? String, "other.html")
        XCTAssertNil(global?["tabId"])
        let own = await call("getOptions", try tab(first, webKitId: 4)).result as? [String: Any]
        XCTAssertEqual(own?["enabled"] as? Bool, false)
        XCTAssertNil(own?["path"], "tab options never inherit a path")
        XCTAssertEqual(own?["tabId"] as? Int, 4)
    }

    func testOptionsEndWithTheExtension() async throws {
        await call("setOptions", ["enabled": false])
        await call("open", gesture(thisWindow))
        await registry.disable(extensionId: extensionId)
        try await registry.enable(extensionId: extensionId)

        let options = await call("getOptions").result as? [String: Any]
        XCTAssertEqual(options?["enabled"] as? Bool, true, "Chrome keeps options for the session only")
    }

    // MARK: - open and close

    func testOpenNeedsAUserGesture() async throws {
        let (_, refused) = await call("open", thisWindow)
        XCTAssertEqual(refused, "`sidePanel.open()` may only be called in response to a user gesture.")

        registry.noteUserGesture(extensionId: extensionId)
        let (_, error) = await call("open", thisWindow)
        XCTAssertNil(error, "right after a toolbar click, command or menu item")
    }

    func testOpenAndCloseReportChromesErrors() async throws {
        var unknownTab = try tab(first, webKitId: 5)
        unknownTab["tab"] = nil

        let missing = await call("open", gesture([:])).error
        XCTAssertEqual(missing, "At least one of `tabId` and `windowId` must be provided")
        let noTab = await call("close", unknownTab).error
        XCTAssertEqual(noTab, "No tab with id: 5.")
        let noWindow = await call("open", gesture(["windowId": 3, "windowPosition": -1])).error
        XCTAssertEqual(noWindow, "No window with id: 3.")
        let notTabSpecific = await call("close", try tab(first, webKitId: 5)).error
        XCTAssertEqual(notTabSpecific, "No active tab-specific side panel for tabId: 5")
        let notOpen = await call("close", thisWindow).error
        XCTAssertNil(notOpen, "closing a closed panel is a no-op")
    }

    func testCloseClosesOnlyTheExtensionsOwnPanel() async throws {
        let otherId = try await install("Other")
        await call("open", gesture(thisWindow), from: otherId)

        await call("close", thisWindow)
        XCTAssertEqual(window.sidePanel.shown?.extensionId, otherId)

        await call("close", thisWindow, from: otherId)
        XCTAssertNil(window.sidePanel.shown)
    }

    func testTheToolbarActionTogglesThePanelWhenAsked() async throws {
        let toggle = try XCTUnwrap(registry.toggleSidePanelOnActionClick)
        XCTAssertFalse(toggle(extensionId, window), "without openPanelOnActionClick the click goes to the popup or onClicked")

        await call("setPanelBehavior", ["openPanelOnActionClick": true])
        XCTAssertTrue(toggle(extensionId, window))
        XCTAssertEqual(window.sidePanel.shown, .init(extensionId: extensionId, tabId: nil))
        XCTAssertFalse(registry.hasRecentUserGesture(extensionId: extensionId), "Chrome grants no gesture for this click")

        XCTAssertTrue(toggle(extensionId, window))
        XCTAssertNil(window.sidePanel.shown)
        UserDefaults.lilo.removeObject(forKey: "sidePanel.\(registry.profileId).\(extensionId!)")
    }

    // MARK: - Events

    func testOpenedAndClosedReachTheExtensionWithChromesPayload() async throws {
        let pageURL = try XCTUnwrap(URL(string: "chrome-extension://\(extensionId!)/listener.html"))
        let listener = try XCTUnwrap(window.createTabStateFirst(url: pageURL)?.id)
        let listening = await pollUntil { self.window.tabManager.engineTab(for: listener)?.currentTitle == "listening" }
        XCTAssertTrue(listening)
        window.activateTabStateFirst(id: first)
        func title() -> String { window.tabManager.engineTab(for: listener)?.currentTitle ?? "" }

        await call("open", gesture(thisWindow))
        let opened = await pollUntil { title().hasPrefix("opened ") }
        XCTAssertTrue(opened)
        XCTAssertTrue(title().hasSuffix(#""path":"/panel.html"}"#), title())
        XCTAssertFalse(title().contains("tabId"), "only a tab-specific panel names its tab")

        window.sidePanel.closePanel()
        let closed = await pollUntil { title().hasPrefix("closed ") }
        XCTAssertTrue(closed)
    }

    func testAWindowClosingClosesItsPanel() async throws {
        await call("open", gesture(thisWindow))
        window.sidePanel.closeAll()

        XCTAssertNil(window.sidePanel.shown)
        XCTAssertNil(window.sidePanel.webView)
    }

}
