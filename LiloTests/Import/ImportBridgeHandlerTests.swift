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
        try Data(#"{"profile": {"info_cache": {"Profile 1": {"name": "Lilas perso"}}}}"#.utf8).write(to: chrome.appendingPathComponent("Local State"))
        try Data("{}".utf8).write(to: chrome.appendingPathComponent("Profile 1/Bookmarks"))
        // EACCES stands in for the EPERM macOS returns until Full Disk Access is granted.
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: chrome.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chrome.path)
            try? fm.removeItem(at: home)
        }
        let router = BridgeRouter(chromeWebView: WKWebView())
        let events = BridgeEventRecorder(router)
        let handler = ImportBridgeHandler(bridgeRouter: router, home: home) { fatalError("no import runs here") }
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
        XCTAssertEqual((chromeSource(1)?["profiles"] as? [[String: Any]])?.map { $0["name"] as? String }, ["Lilas perso"])
        // The handler holds the router weakly, and its activation observer holds the handler weakly.
        withExtendedLifetime((router, handler)) {}
    }
}
