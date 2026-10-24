import AppKit
import WebKit
import XCTest
@testable import Lilo

/// The chrome.tabs, windows, webNavigation, sidePanel, permissions and cookies members Lilo adds that
/// act on a window, through the real gap router and a window showing the extension's profile.
@MainActor
final class WindowGapAPITests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var registry: ProfileExtensionRegistry!
    private var router: GapBridgeRouter!
    private var extensionId: String!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        registry = try context.profileContexts.context(for: profileId).extensions
        window = makeTestWindow(context, showing: space.id, size: NSSize(width: 1000, height: 800))
        window.setupExtensions()
        router = context.engineFactory.gapRouter

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("window-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Window", "version": "1.0",
            "permissions": ["cookies", "sidePanel", "webNavigation"],
            "host_permissions": ["https://allowed.test/*"],
            "optional_host_permissions": ["https://*/*"],
            "side_panel": ["default_path": "panel.html"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try "<!doctype html>".write(to: directory.appendingPathComponent("panel.html"), atomically: true, encoding: .utf8)
        try await registry.load(from: directory)
        extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        registry = nil
        router = nil
        browserContext.tearDown()
        browserContext = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func call(_ namespace: String, _ method: String, _ params: [String: Any] = [:]) async -> (result: Any?, error: String?) {
        await router.route(namespace: namespace, method: method, params: params, extensionId: extensionId, fromWorker: true, registry: registry)
    }

    /// Opens `url` in a new active tab and returns its id and its position as the extension sees it.
    private func openTab(_ url: String) throws -> (id: UUID, position: [String: Int]) {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: url)))
        let adapter = try XCTUnwrap(window.tabManager.tabAdapter(for: tab.id))
        return (tab.id, try XCTUnwrap(registry.tabPosition(of: adapter, extensionId: extensionId)))
    }

    private func queued(_ name: String) -> [[String: Any]] {
        registry.gapEvents.undelivered(to: extensionId)
            .filter { "\($0.namespace).\($0.event)" == name }
            .compactMap { $0.args.first as? [String: Any] }
    }

    private func offersHostAccessRequest(on tabId: UUID) -> Bool {
        let rows = registry.extensionBridgePayloads(activeTab: window.tabManager.tabAdapter(for: tabId))
        return rows.first { $0["id"] as? String == extensionId }?["hostAccessRequest"] as? Bool == true
    }

    // MARK: - permissions host access requests

    func testAHostAccessRequestIsOfferedUntilTheTabLeavesItsOrigin() async throws {
        let tab = try openTab("https://other.test/page")

        let added = await call("permissions", "addHostAccessRequest", ["tab": tab.position])
        XCTAssertNil(added.error)
        XCTAssertTrue(offersHostAccessRequest(on: tab.id))
        let mismatched = await call("permissions", "removeHostAccessRequest", ["tab": tab.position, "pattern": "https://x.test/*"])
        XCTAssertEqual(mismatched.error, "Extension cannot remove a host access request that doesn't exist.")

        registry.access.tabDidCommitNavigation(tab.id, url: URL(string: "https://third.test/"))
        XCTAssertFalse(offersHostAccessRequest(on: tab.id))
    }

    func testAHostAccessRequestFailsAsChromeDoes() async throws {
        let allowed = try openTab("https://allowed.test/")
        let other = try openTab("https://other.test/")

        let hasAccess = await call("permissions", "addHostAccessRequest", ["tab": allowed.position])
        let invalid = await call("permissions", "addHostAccessRequest", ["tab": other.position, "pattern": "bad"])
        let outside = await call("permissions", "addHostAccessRequest", ["tab": other.position, "pattern": "http://x.test/*"])
        XCTAssertEqual(hasAccess.error, "Extension cannot add a host access request for a host it already has access to.")
        XCTAssertEqual(invalid.error, "Extension cannot add a request with an invalid value for 'pattern'.")
        XCTAssertEqual(outside.error, "Extension cannot add a host access request with a pattern that does match any of its host permissions.")
    }

    func testAcceptingAHostAccessRequestGrantsTheSite() async throws {
        let tab = try openTab("https://other.test/page")
        _ = await call("permissions", "addHostAccessRequest", ["tab": tab.position])

        await registry.access.acceptHostAccessRequest(extensionId: extensionId, on: registry.delegate.windowAdapter?.visibleActiveAdapter)

        let context = try XCTUnwrap(registry.context(for: extensionId))
        XCTAssertTrue(context.hasAccess(to: try XCTUnwrap(URL(string: "https://other.test/else"))))
        XCTAssertFalse(offersHostAccessRequest(on: tab.id))
    }

    // MARK: - windows.create popups

    func testAPopupWindowIsOpenForContextsLoadedAfterIt() throws {
        let context = try XCTUnwrap(registry.context(for: extensionId))
        let panel = try XCTUnwrap(registry.delegate.presentExtensionPanel(
            url: nil, type: .popup, for: context, controller: registry.controller, size: NSSize(width: 320, height: 240)
        ))
        defer { panel.nsWindow?.close() }

        // WebKit asks for the open windows when a context loads, and finds a content script's tab among them.
        XCTAssertTrue(registry.extensionWindows.last === panel)
        let position = try XCTUnwrap(registry.extensionWindows.firstIndex { $0 === panel })
        let tab = registry.tabAdapters(atPositions: [["windowPosition": position, "index": 0]], extensionId: extensionId).first ?? nil
        XCTAssertNotNil(tab)
        panel.nsWindow?.close()
        XCTAssertFalse(registry.extensionWindows.contains { $0 === panel })
    }

    // MARK: - openerTabId

    /// A tab a page opens (a `target=_blank` link, a Command-click) names that page's tab as its opener, as in Chrome.
    func testATabAPageOpensHasThePageAsItsOpener() throws {
        let opener = try openTab("https://allowed.test/")
        let before = Set(window.tabManager.openTabs.map(\.id))

        window.tab(try XCTUnwrap(window.tabManager.engineTab(for: opener.id)), didCreateNewTab: URL(string: "https://allowed.test/next"), inBackground: true)

        let created = try XCTUnwrap(window.tabManager.openTabs.first { !before.contains($0.id) })
        let openerAdapter = try XCTUnwrap(window.tabManager.tabAdapter(for: opener.id))
        XCTAssertTrue(window.tabManager.tabAdapter(for: created.id)?.parent === openerAdapter)
    }

    // MARK: - tabs urls

    func testTabsShowsEveryTabURLAndAnEmptyTabAsChromesNewTabPage() async throws {
        let server = try await TinyHTTPServer(index: "<title>Page</title><p>page</p>")
        let url = "http://127.0.0.1:\(server.port)/"
        let page = try openTab(url)
        let loaded = await pollUntil { self.window.tabManager.engineTab(for: page.id)?.currentTitle == "Page" }
        XCTAssertTrue(loaded, "the page loads")
        let emptyTab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let empty = try XCTUnwrap(registry.tabPosition(of: try XCTUnwrap(window.tabManager.tabAdapter(for: emptyTab.id)), extensionId: extensionId))
        let withoutTabs = await call("tabs", "urls", ["tabs": [page.position, empty]])
        XCTAssertEqual((withoutTabs.result as? [Any])?.count, 0, "without tabs, nothing more shows")

        let folder = directory.appendingPathComponent("tabs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Tabs", "version": "1.0", "permissions": ["tabs"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first { $0.id != extensionId }?.id)
        let shown = await router.route(namespace: "tabs", method: "urls", params: ["tabs": [page.position, empty]], extensionId: id, fromWorker: true, registry: registry)
        XCTAssertEqual(shown.result as? [[String]], [[url, "Page"], ["chrome://newtab/", "New Tab"]])
    }

    // MARK: - cookies.getPartitionKey

    func testPartitionKeyOfAMainFrameIsItsSite() async throws {
        let allowed = try openTab("https://allowed.test/page")
        let other = try openTab("https://other.test/")

        let key = await call("cookies", "getPartitionKey", ["tab": allowed.position])
        let refused = await call("cookies", "getPartitionKey", ["tab": other.position])

        let partitionKey = (key.result as? [String: Any])?["partitionKey"] as? [String: Any]
        XCTAssertEqual(partitionKey?["topLevelSite"] as? String, "https://allowed.test")
        XCTAssertEqual(partitionKey?["hasCrossSiteAncestor"] as? Bool, false)
        XCTAssertEqual(refused.error, "No host permissions for cookies at url: \"https://other.test/\".")
    }

    func testRegistrableDomainKeepsThePublicSuffixAndOneLabel() {
        XCTAssertEqual(CookiesBridgeHandler.registrableDomain(of: "a.b.example.co.uk"), "example.co.uk")
        XCTAssertEqual(CookiesBridgeHandler.registrableDomain(of: "www.example.com"), "example.com")
        XCTAssertEqual(CookiesBridgeHandler.registrableDomain(of: "192.168.1.10"), "192.168.1.10")
        XCTAssertEqual(CookiesBridgeHandler.site(of: try! XCTUnwrap(URL(string: "https://Sub.Example.com:8443/x"))), "https://example.com")
    }

    // MARK: - tabs zoom settings

    func testZoomSettingsDefaultToAutomaticPerOrigin() async throws {
        let tab = try openTab("https://allowed.test/")

        let settings = await call("tabs", "getZoomSettings", ["tab": tab.position])

        let result = try XCTUnwrap(settings.result as? [String: Any])
        XCTAssertEqual(result["mode"] as? String, "automatic")
        XCTAssertEqual(result["scope"] as? String, "per-origin")
        XCTAssertEqual(result["defaultZoomFactor"] as? Double, browserContext.context.settingsStore.defaultZoom)
    }

    func testManualZoomLeavesTheZoomToTheExtension() async throws {
        let tab = try openTab("https://allowed.test/")
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        let manual = await call("tabs", "setZoomSettings", ["tab": tab.position, "mode": "manual"])
        XCTAssertNil(manual.error)

        window.zoomActiveTab(by: 0.1)

        XCTAssertEqual(engine.pageZoom, 1, accuracy: 0.001)
        let change = try XCTUnwrap(queued("tabs.onZoomChange").last)
        XCTAssertEqual(change["newZoomFactor"] as? Double ?? 0, 1.1, accuracy: 0.001)
        XCTAssertEqual(change["zoomSettings"] as? [String: String], ["mode": "manual", "scope": "per-tab"])
    }

    func testDisabledZoomResetsTheTabAndIgnoresZooming() async throws {
        let tab = try openTab("https://allowed.test/")
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        engine.setPageZoom(1.5)
        XCTAssertEqual(queued("tabs.onZoomChange").last?["newZoomFactor"] as? Double ?? 0, 1.5, accuracy: 0.001)

        let disabled = await call("tabs", "setZoomSettings", ["tab": tab.position, "mode": "disabled"])
        XCTAssertNil(disabled.error)
        window.zoomActiveTab(by: 0.1)

        XCTAssertEqual(engine.pageZoom, browserContext.context.settingsStore.defaultZoom, accuracy: 0.001)
    }

    // MARK: - tabs split views

    func testTwoAdjacentTabsSplitAndUnsplit() async throws {
        let left = try openTab("https://allowed.test/a")
        let right = try openTab("https://allowed.test/b")
        let params: [String: Any] = ["tabs": [left.position, right.position], "tabIds": [1, 2]]

        let created = await call("tabs", "createSplit", params)
        let splitViewId = try XCTUnwrap(created.result as? Int, created.error ?? "")
        XCTAssertEqual(window.tabManager.tab(for: left.id)?.groupId.flatMap(window.tabManager.folder(id:))?.isSplit, true)
        let again = await call("tabs", "createSplit", params)
        XCTAssertEqual(again.error, "Tab ID 1 is already in a split view.")

        let unsplit = await call("tabs", "unsplit", ["splitViewId": splitViewId])
        XCTAssertNil(unsplit.error)
        XCTAssertNil(window.tabManager.tab(for: left.id)?.groupId)
        let unsplitAgain = await call("tabs", "unsplit", ["splitViewId": splitViewId])
        XCTAssertEqual(unsplitAgain.error, "No split view with id: \(splitViewId).")
        let none = await call("tabs", "unsplit", ["splitViewId": -1])
        XCTAssertEqual(none.error, "Invalid split view id: -1.")
    }

    // MARK: - events

    func testWindowAndNavigationEventsCarryPositions() async throws {
        let source = try openTab("https://allowed.test/")

        window.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: source.id))
        window.tab(engine, didCreateNewTab: URL(string: "https://allowed.test/next"), inBackground: true)

        XCTAssertEqual(queued("windows.onBoundsChanged").map { $0["windowPosition"] as? Int }, [source.position["windowPosition"]])
        let created = try XCTUnwrap(queued("webNavigation.onCreatedNavigationTarget").first)
        XCTAssertEqual(created["source"] as? [String: Int], source.position)
        XCTAssertEqual(created["url"] as? String, "https://allowed.test/next")
        XCTAssertNotEqual(created["tab"] as? [String: Int], source.position)
    }

    // MARK: - sidePanel

    func testSidePanelReportsItsOpenAndClose() async throws {
        let tab = try openTab("https://allowed.test/")
        let thisWindow: [String: Any] = ["windowId": 1, "windowPosition": try XCTUnwrap(window.window.flatMap { registry.windowPosition(of: $0, extensionId: extensionId) })]

        let opened = await call("sidePanel", "open", thisWindow.merging(["userGesture": true]) { $1 })
        XCTAssertNil(opened.error)
        let heard = await pollUntil { !self.queued("sidePanel.onOpened").isEmpty }
        XCTAssertTrue(heard, "after the panel's first load")
        XCTAssertEqual(queued("sidePanel.onOpened").first?["path"] as? String, "/panel.html")
        XCTAssertEqual(queued("sidePanel.onOpened").first?["windowPosition"] as? Int, thisWindow["windowPosition"] as? Int)
        XCTAssertNil(queued("sidePanel.onOpened").first?["index"], "only a tab-specific panel names its tab")
        let tabClose = await call("sidePanel", "close", ["tabId": 5, "tab": tab.position])
        XCTAssertEqual(tabClose.error, "No active tab-specific side panel for tabId: 5")
        let windowClose = await call("sidePanel", "close", thisWindow)
        XCTAssertNil(windowClose.error)

        XCTAssertEqual(queued("sidePanel.onClosed").first?["path"] as? String, "/panel.html", "closing the panel reports it")
    }

    func testSidePanelOpensItsPathWithQueryAndFragment() async throws {
        _ = try openTab("https://allowed.test/")
        let context = try XCTUnwrap(registry.context(for: extensionId))
        let thisWindow: [String: Any] = ["windowId": 1, "windowPosition": try XCTUnwrap(window.window.flatMap { registry.windowPosition(of: $0, extensionId: extensionId) })]
        _ = await call("sidePanel", "setOptions", ["path": "panel.html?view=side#top"])

        let opened = await call("sidePanel", "open", thisWindow.merging(["userGesture": true]) { $1 })

        XCTAssertNil(opened.error)
        let expected = context.baseURL.absoluteString + "panel.html?view=side#top"
        let shown = await pollUntil { self.registry.delegate.extensionViews(of: context).contains { $0.url.absoluteString == expected } }
        XCTAssertTrue(shown, "the panel loads its path with the query and fragment, as in Chrome")
        _ = await call("sidePanel", "close", thisWindow)
    }

    // MARK: - private windows

    /// WebKit lists [N1, P1, N2]: this window, its private window P1 showing one tab, and another window N2.
    func testAnExtensionWithoutPrivateAccessNeverReachesAPrivateTab() async throws {
        let privateTab = try openTab("https://allowed.test/private")
        let otherTab = try openTab("https://allowed.test/other")
        let thisWindow = try XCTUnwrap(registry.delegate.windowAdapter)
        let privateWindow = registry.windowAdapter(for: try XCTUnwrap(window.window), isPrivate: true)
        let otherNSWindow = NSWindow()
        let otherWindow = registry.windowAdapter(for: otherNSWindow)
        let privateAdapter = try XCTUnwrap(window.tabManager.tabAdapter(for: privateTab.id))
        let otherAdapter = try XCTUnwrap(window.tabManager.tabAdapter(for: otherTab.id))
        for (adapter, target) in [(privateAdapter, privateWindow), (otherAdapter, otherWindow)] {
            thisWindow.remove(tab: adapter)
            target.add(tab: adapter)
            adapter.extensionWindow = target
        }
        XCTAssertTrue(registry.extensionWindows.elementsEqual([thisWindow, privateWindow, otherWindow], by: ===))
        let context = try XCTUnwrap(registry.context(for: extensionId))
        XCTAssertFalse(context.hasAccessToPrivateData)

        for windowPosition in 0..<4 {
            for index in 0..<4 {
                let found = registry.tabAdapters(atPositions: [["windowPosition": windowPosition, "index": index]], extensionId: extensionId)
                XCTAssertFalse(found.first ?? nil === privateAdapter, "position \(windowPosition), \(index)")
            }
        }
        XCTAssertTrue(registry.tabAdapters(atPositions: [["windowPosition": 1, "index": 0]], extensionId: extensionId).first ?? nil === otherAdapter)
        XCTAssertNil(registry.tabPosition(of: privateAdapter, extensionId: extensionId))
        XCTAssertEqual(registry.tabPosition(of: otherAdapter, extensionId: extensionId), ["windowPosition": 1, "index": 0])
        XCTAssertEqual(registry.windowPosition(of: otherNSWindow, extensionId: extensionId), 1)
        XCTAssertTrue(registry.extensionWindow(at: 1, extensionId: extensionId) === otherWindow)

        try XCTUnwrap(window.tabManager.engineTab(for: privateTab.id)).reportZoomChange(from: 1, to: 2)
        XCTAssertTrue(queued("tabs.onZoomChange").isEmpty, "no event about a private tab")
        try XCTUnwrap(window.tabManager.engineTab(for: otherTab.id)).reportZoomChange(from: 1, to: 2)
        XCTAssertEqual(queued("tabs.onZoomChange").map { [$0["windowPosition"] as? Int, $0["index"] as? Int] }, [[1, 0]])

        context.hasAccessToPrivateData = true
        XCTAssertTrue(registry.tabAdapters(atPositions: [["windowPosition": 1, "index": 0]], extensionId: extensionId).first ?? nil === privateAdapter)
        try XCTUnwrap(window.tabManager.engineTab(for: privateTab.id)).reportZoomChange(from: 2, to: 1)
        XCTAssertEqual(queued("tabs.onZoomChange").last.map { [$0["windowPosition"] as? Int, $0["index"] as? Int] }, [1, 0])
        registry.notifyWindowClosed(for: otherNSWindow)
    }
}
