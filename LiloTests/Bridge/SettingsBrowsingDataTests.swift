import WebKit
import XCTest
@testable import Lilo

/// The clear-data page measures what the window's profile stores, and measures it again once a clear is done.
@MainActor
final class SettingsBrowsingDataTests: XCTestCase {
    func testSizesCoverTheHistoryAndSiteStorageAndDropOnceCleared() async throws {
        let database = try TemporaryProfileDatabase()
        addTeardownBlock { database.tearDown() }
        let history = HistoryStore(dbPool: database.pool)
        history.scheduleRecordVisit(url: "https://a.test/", title: "A")
        history.flushPendingWrites()

        let id = UUID()
        let dataStore = WKEngineFactory().createDataStore(persistent: true, identifier: id.uuidString)
        addTeardownBlock { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore.backingStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<p>a</p>", baseURL: URL(string: "https://a.test/"))
        _ = await pollUntil { webView.url?.host == "a.test" && !webView.isLoading }
        _ = try await webView.evaluateJavaScript("localStorage.setItem('k', 'x'.repeat(200000)); true")

        let settingsStore = SettingsStore(dbPool: database.pool)
        let router = BridgeRouter(chromeWebView: WKWebView())
        let recorder = BridgeEventRecorder(router)
        let sitePermissions = SitePermissionStore(dbPool: database.pool)
        let handler = SettingsBridgeHandler(
            settingsStore: settingsStore, sitePermissionStoreProvider: { sitePermissions },
            zoomStoreProvider: { nil }, historyStoreProvider: { history }, extensionRegistryProvider: { nil },
            dataStoreProvider: { dataStore }, lifecycleDiagnosticsProvider: { nil }, extensionDiagnosticsProvider: { [] },
            forceLifecycleTrimHandler: {}, bridgeRouter: router
        )
        func send(_ action: String, _ payload: [String: Any] = [:]) async throws {
            _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload])))
        }
        // The handler holds the settings store weakly.
        defer { withExtendedLifetime(settingsStore) {} }
        func latestSizes() -> [String: Any]? { recorder.events.last { $0.name == "browsingDataSizesLoaded" }?.data }

        // WebKit writes local storage to disk on its own schedule.
        let measured = await pollUntil(timeout: 10) {
            try? await send("getBrowsingDataSizes")
            return (latestSizes()?["storage"] as? Int64 ?? 0) > 0
        }
        XCTAssertTrue(measured, "the site's local storage is measured")
        XCTAssertEqual(latestSizes()?["historyEntries"] as? Int, 1)
        XCTAssertGreaterThan(latestSizes()?["history"] as? Int64 ?? 0, 0)

        try await send("clearBrowsingData", ["kinds": ["history", "siteData"], "range": "all"])
        _ = await pollUntil(timeout: 5) { recorder.events.contains { $0.name == "settingsActionCompleted" } }

        XCTAssertEqual(latestSizes()?["historyEntries"] as? Int, 0)
        XCTAssertEqual(latestSizes()?["storage"] as? Int64, 0)
        XCTAssertEqual(latestSizes()?["cookies"] as? Int64, 0)
        let completed = try XCTUnwrap(recorder.events.last { $0.name == "settingsActionCompleted" }?.data)
        XCTAssertEqual(completed["action"] as? String, "clearBrowsingData")
        XCTAssertEqual(completed["level"] as? String, "info")
    }

    func testClearingFromAPrivateSpaceClearsTheProfile() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "Private", profileId: profileId, isPrivate: true)
        let window = makeTestWindow(context, showing: space.id)
        defer { window.close() }
        let cookieStore = context.profileManager.dataStore(for: profileId).backingStore.httpCookieStore
        await cookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: "sid", .value: "1", .expires: Date(timeIntervalSinceNow: 3600)
        ])))

        window.setupBridgeLate()
        let handler = try XCTUnwrap(window.bridgeRouter.handlers["clearBrowsingData"])
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "clearBrowsingData", "payload": ["kinds": ["cookies"], "range": "all"]
        ])))

        let remaining = await cookieStore.allCookies()
        XCTAssertEqual(remaining.map(\.name), [], "the profile's cookies outlive a clear made from its private space")
    }

    func testClearingHistoryForgetsTheProfilesRecentlyClosedPages() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let otherSpace = try context.spaceManager.createSpace(name: "O", profileId: try context.profileManager.createProfile(name: "O").id)
        let window = makeTestWindow(context, showing: space.id)
        window.setupBridgeLate()
        let terminal = RecentlyClosedStack.Entry.Content.terminal(.init(cwd: "/"))
        for (content, spaceId) in [
            (.page(URL(string: "https://cleared.example/")!), space.id),
            (terminal, space.id),
            (.page(URL(string: "https://other-profile.example/")!), otherSpace.id)
        ] as [(RecentlyClosedStack.Entry.Content, UUID)] {
            context.recentlyClosed.push(content, spaceId: spaceId, parentFolderId: nil, section: nil, sortOrder: nil)
        }
        let handler = try XCTUnwrap(window.bridgeRouter.handlers["clearBrowsingData"] as? SettingsBridgeHandler)

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "clearBrowsingData", "payload": ["kinds": ["history"], "range": "hour"]
        ])))

        XCTAssertEqual(context.recentlyClosed.recentEntries.map(\.content), [.page(URL(string: "https://other-profile.example/")!), terminal])
    }
}
