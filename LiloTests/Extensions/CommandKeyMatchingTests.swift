import AppKit
import GRDB
import XCTest
import WebKit
@testable import Lilo

/// The central keyboard monitor dispatches keyDown events to loaded extension commands. WebKit owns
/// the shortcut matching, so these drive the real registry with real events.
@MainActor
final class CommandKeyMatchingTests: XCTestCase {
    private var registry: ProfileExtensionRegistry!
    private var tempDir: URL!
    private var storage: ExtensionStorage!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let profileId = TestProfileIds.next()
        storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
    }

    override func tearDown() {
        registry = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Loads an extension whose command suggests `key` (Command+Shift+Y by default), and returns its id.
    @discardableResult
    private func loadCommandExtension(named name: String = "Commands", key: String = "Command+Shift+Y") async throws -> String {
        let extDir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"\(name)","version":"1.0","description":"Command test",\
        "commands":{"test-command":{"suggested_key":{"default":"Ctrl+Shift+Y","mac":"\(key)"},"description":"Test"}}}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try await registry.load(from: extDir)
        return try XCTUnwrap(registry.loadedExtensions.first { $0.context.webExtension.displayName == name }?.id)
    }

    private func commandKey(of id: String) -> String? {
        let row = registry.extensionBridgePayloads(activeTab: nil).first { $0["id"] as? String == id }
        return (row?["commands"] as? [[String: Any]])?.first { $0["id"] as? String == "test-command" }?["key"] as? String
    }

    private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    func testMatchingShortcutIsSwallowed() async throws {
        try await loadCommandExtension()

        let event = try keyEvent(characters: "y", modifiers: [.command, .shift])

        XCTAssertTrue(registry.handleExtensionKeyDown(event), "a declared shortcut must be dispatched and swallowed")
    }

    func testNonMatchingShortcutsAreNotSwallowed() async throws {
        try await loadCommandExtension()

        let wrongKey = try keyEvent(characters: "x", modifiers: [.command, .shift])
        let wrongModifiers = try keyEvent(characters: "y", modifiers: [.command])
        let noModifiers = try keyEvent(characters: "y", modifiers: [])

        XCTAssertFalse(registry.handleExtensionKeyDown(wrongKey))
        XCTAssertFalse(registry.handleExtensionKeyDown(wrongModifiers))
        XCTAssertFalse(registry.handleExtensionKeyDown(noModifiers))
    }

    func testReboundShortcutReplacesTheManifestOneAndSurvivesARestore() async throws {
        try await loadCommandExtension()
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)

        await registry.access.setCommandShortcut(extensionId: id, commandId: "test-command", key: "k", modifiers: [.command, .option])

        XCTAssertFalse(registry.handleExtensionKeyDown(try keyEvent(characters: "y", modifiers: [.command, .shift])))
        XCTAssertTrue(registry.handleExtensionKeyDown(try keyEvent(characters: "k", modifiers: [.command, .option], keyCode: 40)))
        let command = (registry.extensionBridgePayloads(activeTab: nil).first?["commands"] as? [[String: Any]])?.first { $0["id"] as? String == "test-command" }
        XCTAssertEqual(command?["key"] as? String, "k")

        let profileId = registry.profileId
        registry.teardown()
        registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        await registry.restore()
        XCTAssertTrue(registry.handleExtensionKeyDown(try keyEvent(characters: "k", modifiers: [.command, .option], keyCode: 40)))
    }

    func testSuggestedKeyAnotherExtensionHoldsStaysUnset() async throws {
        let first = try await loadCommandExtension()
        let second = try await loadCommandExtension(named: "Second")

        XCTAssertEqual(commandKey(of: first), "y")
        XCTAssertEqual(commandKey(of: second), "", "the later extension shows no shortcut, as in Chrome")

        await registry.disable(extensionId: first)
        await registry.disable(extensionId: second)
        try await registry.enable(extensionId: second)
        XCTAssertEqual(commandKey(of: second), "", "loading alone does not hand it the key back")
    }

    func testSuggestedKeyALiloShortcutHoldsStaysUnset() async throws {
        let id = try await loadCommandExtension(key: "Command+T")

        XCTAssertEqual(commandKey(of: id), "")
        XCTAssertFalse(registry.handleExtensionKeyDown(try keyEvent(characters: "t", modifiers: [.command], keyCode: 17)))
    }

    func testRecordingKeysSomethingElseHoldsIsRefused() async throws {
        try await loadCommandExtension()
        let second = try await loadCommandExtension(named: "Second", key: "Command+Shift+U")
        let handler = ExtensionUIBridgeHandler(extensionRegistryProvider: { [unowned self] in self.registry })
        var refusals: [String?] = []
        handler.onActionCompleted = { _, action, success, error in
            if action == "shortcut", !success { refusals.append(error) }
        }
        func record(_ key: String, _ modifiers: NSEvent.ModifierFlags) async throws {
            let message = try XCTUnwrap(BridgeMessage(dictionary: ["action": "setExtensionCommandShortcut", "payload": [
                "id": second, "command": "test-command", "key": key, "modifiers": modifiers.rawValue
            ]]))
            _ = await handler.handle(message: message)
        }

        try await record("y", [.command, .shift])
        try await record("t", [.command])

        XCTAssertEqual(refusals.count, 2)
        XCTAssertEqual(refusals.first, "Commands")
        XCTAssertEqual(commandKey(of: second), "u", "a refused shortcut leaves the command as it was")

        try await record("o", [.command, .shift])
        XCTAssertEqual(refusals.count, 2)
        XCTAssertEqual(commandKey(of: second), "o")
    }

    func testNoCommandsMeansNothingIsSwallowed() async throws {
        let extDir = tempDir.appendingPathComponent("NoCommands")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"NoCommands","version":"1.0","description":"No commands"}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try await registry.load(from: extDir)

        let event = try keyEvent(characters: "y", modifiers: [.command, .shift])

        XCTAssertFalse(registry.handleExtensionKeyDown(event))
    }
}
