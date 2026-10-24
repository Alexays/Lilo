import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ImportBridgeHandlerTests: XCTestCase {
    func testComingBackToLiloRescansABrowserItCouldNotRead() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try fm.createDirectory(at: chrome.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
        try Data(#"{"profile": {"info_cache": {"Profile 1": {"name": "Personal"}}}}"#.utf8).write(to: chrome.appendingPathComponent("Local State"))
        try Data("{}".utf8).write(to: chrome.appendingPathComponent("Profile 1/Bookmarks"))
        // EACCES stands in for the EPERM macOS returns until Full Disk Access is granted.
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: chrome.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chrome.path)
            try? fm.removeItem(at: home)
        }
        let router = BridgeRouter(chromeWebView: WKWebView())
        let events = BridgeEventRecorder(router)
        let handler = ImportBridgeHandler(bridgeRouter: router, home: home, holdExtensionTabs: { _ in }, makeImporter: { fatalError("no import runs here") })
        let scans = { events.events.filter { $0.name == "importSourcesLoaded" } }
        let chromeSource = { (index: Int) in
            (scans().dropFirst(index).first?.data["sources"] as? [[String: Any]])?.first { $0["id"] as? String == "chrome" }
        }

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "scanImportSources", "payload": [:]])))
        let scanned = await pollUntil(timeout: 5) { scans().count == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(chromeSource(0)?["needsFullDiskAccess"] as? Bool, true)

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chrome.path)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let rescanned = await pollUntil(timeout: 5) { scans().count == 2 }
        XCTAssertTrue(rescanned)
        XCTAssertEqual(chromeSource(1)?["needsFullDiskAccess"] as? Bool, false)
        XCTAssertEqual((chromeSource(1)?["profiles"] as? [[String: Any]])?.map { $0["name"] as? String }, ["Personal"])
        // The handler holds the router weakly, and its activation observer holds the handler weakly.
        withExtendedLifetime((router, handler)) {}
    }

    func testAllowingAccessOpensFullDiskAccessAndClosesItsPanelOnceGranted() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let safari = home.appendingPathComponent("Library/Safari")
        try fm.createDirectory(at: safari, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: safari.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path)
            try? fm.removeItem(at: home)
        }
        let router = BridgeRouter(chromeWebView: WKWebView())
        let events = BridgeEventRecorder(router)
        var opened: [URL] = []
        let handler = ImportBridgeHandler(bridgeRouter: router, home: home, openURL: { opened.append($0); return true },
                                          holdExtensionTabs: { _ in }, makeImporter: { fatalError("no import runs here") })
        let safariSources = { events.events.filter { $0.name == "importSourcesLoaded" }
            .compactMap { ($0.data["sources"] as? [[String: Any]])?.first { $0["id"] as? String == "safari" } } }
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "scanImportSources", "payload": [:]])))
        let scanned = await pollUntil(timeout: 5) { safariSources().count == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(safariSources().first?["needsFullDiskAccess"] as? Bool, true)

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "openFullDiskAccessSettings", "payload": [:]])))
        XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"])
        XCTAssertNotNil(handler.accessPanel)

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path)
        let closed = await pollUntil(timeout: 5) { handler.accessPanel == nil }
        XCTAssertTrue(closed, "the panel closes once the protected folder reads")
        let rescanned = await pollUntil(timeout: 5) { safariSources().count == 2 }
        XCTAssertTrue(rescanned)
        XCTAssertEqual(safariSources().last?["needsFullDiskAccess"] as? Bool, false)
        withExtendedLifetime((router, handler)) {}
    }

    /// A browser profile listing one Web Store extension, and an unpacked extension that opens its welcome page on install.
    private func makeWelcomingExtension() throws -> (home: URL, storeId: String, unpacked: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("import-tabs-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let storeId = String(repeating: "k", count: 32)
        let listed = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Extensions/\(storeId)/1.0")
        try fm.createDirectory(at: listed, withIntermediateDirectories: true)
        try Data(#"{"name": "Welcomer", "update_url": "https://clients2.google.com/service/update2/crx"}"#.utf8)
            .write(to: listed.appendingPathComponent("manifest.json"))
        let unpacked = root.appendingPathComponent("welcomer")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "Welcomer", "version": "1.0", "background": {"service_worker": "worker.js"}}"#.utf8)
            .write(to: unpacked.appendingPathComponent("manifest.json"))
        try Data("chrome.runtime.onInstalled.addListener(() => chrome.tabs.create({ url: 'welcome.html' }));".utf8)
            .write(to: unpacked.appendingPathComponent("worker.js"))
        try Data("<title>Welcome</title>".utf8).write(to: unpacked.appendingPathComponent("welcome.html"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (home, storeId, unpacked)
    }

    private func welcomeTab(in window: MainWindowController) -> Tab? {
        window.tabManager.openTabs.first { $0.url?.lastPathComponent == "welcome.html" }
    }

    func testAnExtensionTheImportReinstallsOpensItsWelcomePageInTheBackground() async throws {
        let browser = try await TemporaryBrowserContext()
        defer { browser.tearDown() }
        let (window, registry) = try browser.makeExtensionWindow()
        let shown = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let (home, storeId, unpacked) = try makeWelcomingExtension()
        let router = BridgeRouter(chromeWebView: WKWebView())
        let events = BridgeEventRecorder(router)
        let sink = BrowserImporter.Sink(
            activeProfileId: { registry.profileId }, activeSpaceId: { window.tabManager.currentSpaceId }, tree: { _ in nil }, apply: { _ in },
            findProfile: { _ in nil }, createProfile: { _ in UUID() }, findSpace: { _, _ in nil }, createSpace: { _, _, _, _ in UUID() },
            loadSpaceState: { _, _ in nil }, saveSpaceStates: { _, _ in }, historyStore: { _ in throw ImportError.missingFile("history") },
            faviconStore: { _ in throw ImportError.missingFile("favicons") }, setCookies: { _, _ in },
            installExtension: { _, _ in try await registry.load(from: unpacked) }, pinnedExtensions: { [] }, pinExtensions: { _ in },
            otherBookmarksTitle: { $0 }, warmFavicons: { _ in })
        let handler = ImportBridgeHandler(bridgeRouter: router, home: home, holdExtensionTabs: { window.holdsExtensionTabsInBackground = $0 },
                                          makeImporter: { BrowserImporter(sink: sink, home: home) })
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "scanImportSources", "payload": [:]])))
        let scanned = await pollUntil(timeout: 5) { events.events.contains { $0.name == "importSourcesLoaded" } }
        XCTAssertTrue(scanned)

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "runImport", "payload": [
            "selections": [["sourceId": "chrome", "profileId": "Default", "kinds": ["extensions"], "extensionIds": [storeId]]]
        ]])))
        let opened = await pollUntil { self.welcomeTab(in: window) != nil }
        XCTAssertTrue(opened, "the reinstalled extension opens its welcome page")
        XCTAssertEqual(window.tabManager.activeTabId, shown.id, "the welcome page waits in the background, the onboarding keeps the window")
        XCTAssertEqual(window.displayedTabIds, [shown.id])

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "closeImport", "payload": [:]])))
        let welcomeId = try XCTUnwrap(welcomeTab(in: window)).id
        let loaded = await pollUntil { window.tabManager.engineTab(for: welcomeId)?.currentTitle == "Welcome" }
        XCTAssertTrue(loaded)
        let page = try XCTUnwrap(window.tabManager.engineTab(for: welcomeId)?.view as? WKWebView)
        _ = try? await page.callAsyncJavaScript("await chrome.tabs.create({ url: 'welcome.html?again' })", contentWorld: .page)
        let activated = await pollUntil { window.tabManager.activeTab?.url?.query == "again" }
        XCTAssertTrue(activated, "once the import's page closes, a tab the extension opens is active, as in Chrome")
        withExtendedLifetime((router, handler)) {}
    }
}
