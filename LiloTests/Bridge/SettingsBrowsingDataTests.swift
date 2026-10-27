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
        let handler = SettingsBridgeHandler(
            settingsStore: settingsStore, sitePermissionStore: SitePermissionStore(dbPool: database.pool),
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
}
