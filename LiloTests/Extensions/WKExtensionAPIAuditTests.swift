import XCTest
import GRDB
import WebKit
@testable import Lilo

@MainActor
final class WKExtensionAPIAuditTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_profileExtensionRegistry_uses_persistent_configuration() {
        let profileId = TestProfileIds.next()
        let registry = try! makeTestExtensionRegistry(profileId: profileId, in: tempDir)
        XCTAssertTrue(registry.controller.configuration.isPersistent)
        XCTAssertEqual(registry.controller.configuration.identifier, profileId)
    }

    func test_commandsHandlerReturnsRegistryCommandsForExtension() async throws {
        let registry = try makeTestExtensionRegistry(in: tempDir)
        let extensionURL = tempDir.appendingPathComponent("command-extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Command Extension",
          "version": "1.0",
          "commands": {
            "do-thing": {
              "description": "Do the thing",
              "suggested_key": { "default": "Ctrl+Shift+Y" }
            }
          }
        }
        """
        try manifest.write(to: extensionURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try await registry.load(from: extensionURL)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)

        let api = CommandsBridgeHandler()
        let message = BridgeMessage(dictionary: [
            "action": "commands.getAll",
            "payload": ["extensionId": extensionId]
        ])
        let message2 = try XCTUnwrap(message, "BridgeMessage init should succeed")
        let result = await api.handle(message2, registry: registry)
        let commands = (result as? [String: Any])?["commands"] as? [[String: Any]]
        XCTAssertEqual(commands?.first?["name"] as? String, "do-thing")
        XCTAssertEqual(commands?.first?["description"] as? String, "Do the thing")
        XCTAssertFalse((commands?.first?["shortcut"] as? String ?? "").isEmpty)
    }

    func test_registry_window_notifications_do_not_crash() {
        let registry = try! makeTestExtensionRegistry(in: tempDir)
        let adapter = WindowExtensionAdapter(nsWindow: NSWindow())
        registry.delegate.windowAdapter = adapter
        // Exercise the whole window-notification surface, including the
        // windowOpenedWasNotified idempotence guard (the second open is a no-op).
        registry.notifyWindowOpened()
        registry.notifyWindowOpened()
        registry.notifyWindowFocused(true)
        registry.notifyWindowFocused(false)
        registry.notifyWindowClosed()
    }

    func test_extensionControllerDelegate_conforms_to_all_delegate_methods() {
        let delegate = ExtensionControllerDelegate()
        let sel1 = #selector(WKWebExtensionControllerDelegate.webExtensionController(_:openNewWindowUsing:for:completionHandler:))
        let sel2 = #selector(WKWebExtensionControllerDelegate.webExtensionController(_:openOptionsPageFor:completionHandler:))
        let sel3 = #selector(WKWebExtensionControllerDelegate.webExtensionController(_:didUpdate:forExtensionContext:))
        let sel4 = #selector(WKWebExtensionControllerDelegate.webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:))
        let sel5 = #selector(WKWebExtensionControllerDelegate.webExtensionController(_:connectUsing:for:completionHandler:))
        XCTAssertTrue(delegate.responds(to: sel1), "openNewWindowUsing not implemented")
        XCTAssertTrue(delegate.responds(to: sel2), "openOptionsPageFor not implemented")
        XCTAssertTrue(delegate.responds(to: sel3), "didUpdateAction not implemented")
        XCTAssertTrue(delegate.responds(to: sel4), "sendMessage:toApplication not implemented")
        XCTAssertTrue(delegate.responds(to: sel5), "connectUsing not implemented")
    }

    func test_webViewTab_extensionContextMenuItemsProvider_is_nil_by_default() {
        let webView = WKWebView()
        let tab = WKWebViewTab(id: UUID(), webView: webView)
        XCTAssertNil(tab.extensionContextMenuItemsProvider, "Provider should be nil by default")
    }
}
