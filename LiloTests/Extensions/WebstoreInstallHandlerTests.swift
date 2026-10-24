import AppKit
import WebKit
import XCTest
@testable import Lilo

/// The Chrome Web Store's native transport, called from a store page in a window's tab.
@MainActor
final class WebstoreInstallHandlerTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    func testTheStoreSeesADisabledExtensionAndCannotReinstallIt() async throws {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let registry = try context.profileContexts.context(for: profileId).extensions
        // A store copy: named by its 32-letter id under the profile's extensions folder.
        let storeId = "abcdefghijklmnopabcdefghijklmnop"
        let directory = try XCTUnwrap(registry.files.directory).appendingPathComponent(storeId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Stored","version":"1.0"}"#.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try await registry.load(from: directory)
        await registry.disable(extensionId: storeId)

        let window = makeTestWindow(context, showing: space.id)
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let page = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)?.view as? WKWebView)
        page.loadHTMLString("<title>Store</title>", baseURL: URL(string: "https://chromewebstore.google.com/"))
        let loaded = await pollUntil { page.title == "Store" }
        XCTAssertTrue(loaded)
        func send(_ body: [String: Any]) async throws -> Any? {
            try await page.callAsyncJavaScript(
                "return await window.webkit.messageHandlers.liloWebstore.postMessage(body)",
                arguments: ["body": body], in: nil, contentWorld: .page
            )
        }

        let listed = try await send(["action": "list"]) as? [[String: Any]]
        let reinstall = try await send(["action": "install", "id": storeId]) as? String

        XCTAssertEqual(listed?.first { $0["id"] as? String == storeId }?["enabled"] as? Bool, false)
        XCTAssertEqual(reinstall, "already_installed", "installing a disabled copy must not enable it behind the user's back")
        XCTAssertTrue(registry.disabledStoredExtensions.contains { $0.id == storeId })
    }
}
