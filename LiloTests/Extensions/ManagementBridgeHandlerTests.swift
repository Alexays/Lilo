import WebKit
import XCTest
@testable import Lilo

/// Covers `ManagementBridgeHandler`: the action set, an empty profile, the
/// permission-warning rules, and listing and uninstalling through a real registry.
@MainActor
final class ManagementBridgeHandlerTests: XCTestCase {

    private func makeHandler() -> ManagementBridgeHandler {
        ManagementBridgeHandler()
    }

    func test_handledActions() {
        XCTAssertEqual(makeHandler().gapActions, [
            "management.getAll",
            "management.get",
            "management.getSelf",
            "management.setEnabled",
            "management.uninstall",
            "management.uninstallSelf",
            "management.getPermissionWarningsById",
            "management.getPermissionWarningsByManifest",
            "management.launchApp",
            "management.createAppShortcut",
            "management.setLaunchType",
            "management.generateAppForLink"
        ])
    }

    /// A registry under a temp directory holding one loaded extension; the caller removes `directory`.
    private func makeRegistryWithExtension() async throws -> (registry: ProfileExtensionRegistry, id: String, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("management-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try makeTestExtensionRegistry(in: directory)
        try await registry.load(from: try createMinimalExtension(named: "managed", displayName: "Managed", in: directory))
        return (registry, try XCTUnwrap(registry.loadedExtensions.first?.id), directory)
    }

    private func send(_ action: String, _ payload: [String: Any], to registry: ProfileExtensionRegistry) async throws -> Any? {
        let message = try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload]))
        return await makeHandler().handle(message, registry: registry)
    }

    func test_getAllAndGet_listADisabledExtension() async throws {
        let (registry, id, directory) = try await makeRegistryWithExtension()
        defer { try? FileManager.default.removeItem(at: directory) }
        await registry.disable(extensionId: id)

        let allResult = try await send("management.getAll", [:], to: registry)
        let singleResult = try await send("management.get", ["id": id], to: registry)
        let all = try XCTUnwrap(allResult as? [[String: Any]])
        let single = try XCTUnwrap(singleResult as? [String: Any])

        XCTAssertEqual(all.map { $0["id"] as? String }, [id])
        XCTAssertEqual(all.first?["enabled"] as? Bool, false)
        XCTAssertEqual(single["name"] as? String, "Managed")
        XCTAssertEqual(single["enabled"] as? Bool, false)
    }

    func test_uninstallSelf_withoutDialog_removesTheCaller() async throws {
        let (registry, id, directory) = try await makeRegistryWithExtension()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await send("management.uninstallSelf", ["extensionId": id], to: registry)

        XCTAssertNil(result as? BridgeError)
        let removed = await pollUntil { registry.loadedExtensions.isEmpty }
        XCTAssertTrue(removed, "the caller is unloaded and forgotten")
        XCTAssertTrue(registry.disabledStoredExtensions.isEmpty)
    }

    func test_uninstall_ofAnUnknownExtension_fails() async throws {
        let (registry, id, directory) = try await makeRegistryWithExtension()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await send("management.uninstall", ["extensionId": id, "id": "missing"], to: registry)

        XCTAssertEqual((result as? BridgeError)?.message, "Extension not found: missing")
        XCTAssertEqual(registry.loadedExtensions.count, 1)
    }

    func test_getAll_inAnEmptyProfile_isEmpty() async throws {
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "management.getAll"]))
        let result = await makeHandler().handle(msg)
        let extensions = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertTrue(extensions.isEmpty)
    }

    func test_get_inAnEmptyProfile_returnsNotFound() async throws {
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "management.get",
            "payload": ["id": "x"]
        ]))
        let result = await makeHandler().handle(msg)
        let error = try XCTUnwrap(result as? BridgeError)
        XCTAssertEqual(error.message, "Extension not found")
    }

    func test_permissionWarnings_flagDangerousPermissionsAndBroadHosts() async throws {
        let manifest: [String: Any] = [
            "permissions": ["tabs", "storage", "history"],
            "host_permissions": ["https://*/*", "https://example.com/*"]
        ]
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "management.getPermissionWarningsByManifest",
            "payload": ["manifest": manifest] as [String: Any]
        ]))
        let result = await makeHandler().handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        let warnings = try XCTUnwrap(dict["warnings"] as? [String])

        // "tabs" and "history" are dangerous, "storage" is safe; "https://*/*" is broad,
        // "https://example.com/*" is narrow. So exactly three warnings.
        XCTAssertTrue(warnings.contains { $0.contains("\"tabs\"") })
        XCTAssertTrue(warnings.contains { $0.contains("\"history\"") })
        XCTAssertFalse(warnings.contains { $0.contains("\"storage\"") })
        XCTAssertTrue(warnings.contains { $0.contains("https://*/*") })
        XCTAssertFalse(warnings.contains { $0.contains("example.com") })
        XCTAssertEqual(warnings.count, 3)
    }

    func test_permissionWarnings_parsesManifestString() async throws {
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "management.getPermissionWarningsByManifest",
            "payload": ["manifestStr": "{\"permissions\":[\"cookies\"]}"]
        ]))
        let result = await makeHandler().handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["warnings"] as? [String], ["This extension requests the \"cookies\" permission"])
    }

    func test_permissionWarnings_emptyWhenNoManifest() async throws {
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "management.getPermissionWarningsByManifest"]))
        let result = await makeHandler().handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["warnings"] as? [String], [])
    }

    func test_permissionWarningsById_inAnEmptyProfile_isEmpty() async throws {
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "management.getPermissionWarningsById",
            "payload": ["id": "x"]
        ]))
        let result = await makeHandler().handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["warnings"] as? [String], [])
    }
}
