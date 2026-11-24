import XCTest
@testable import PluginCore
import TestingSupport

final class PluginManifestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-plugin-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func plugin(_ name: String = "stub") -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    func testLoadsAValidManifest() throws {
        let manifest = try StubPlugin.write(at: plugin(), manifest: [
            "capabilities": ["tabs:read", "files:plugin-dir"],
            "contributes": [
                "tools": [["name": "t", "description": "d", "inputSchema": ["type": "object"]]],
                "settings": [["name": "apiKey", "type": "password", "title": "API key"]]
            ]
        ])
        XCTAssertEqual(manifest.id, "app.lilo.test.stub")
        XCTAssertEqual(manifest.capabilities, [.tabsRead, .filesPluginDir])
        XCTAssertEqual(manifest.contributes.settings.first?.type, .password)
        // Absent `consent` means `read`: the least privilege.
        XCTAssertNil(manifest.contributes.tools.first?.consent)
        XCTAssertEqual(manifest.contributes.tools.first?.consentTier, .read)
    }

    func testContributesDecodesWithEitherKeyAlone() throws {
        let settingsOnly = try StubPlugin.write(at: plugin("settings-only"), manifest: [
            "contributes": ["settings": [["name": "k", "type": "text", "title": "K"]]]
        ])
        XCTAssertEqual(settingsOnly.contributes.settings.map(\.name), ["k"])
        XCTAssertTrue(settingsOnly.contributes.tools.isEmpty)

        let toolsOnly = try StubPlugin.write(at: plugin("tools-only"), manifest: [
            "contributes": ["tools": [["name": "t", "description": "d", "inputSchema": [:]]]]
        ])
        XCTAssertEqual(toolsOnly.contributes.tools.map(\.name), ["t"])
        XCTAssertTrue(toolsOnly.contributes.settings.isEmpty)
    }

    func testRejectsUnknownSchemaKey() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), manifest: ["uiSurface": true])) {
            guard case PluginManifestError.unknownKey(let key) = $0 else {
                return XCTFail("expected unknownKey, got \($0)")
            }
            XCTAssertEqual(key, "uiSurface")
        }
    }

    func testRejectsUnknownCapability() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), manifest: [
            "capabilities": ["settings:store", "network:anywhere"]
        ])) {
            guard case PluginManifestError.unknownCapability(let capability) = $0 else {
                return XCTFail("expected unknownCapability, got \($0)")
            }
            XCTAssertEqual(capability, "network:anywhere")
        }
    }

    func testRejectsUnknownNestedKey() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), manifest: [
            "contributes": ["settings": [["name": "k", "type": "text", "title": "K", "surprise": 1]]]
        ])) {
            guard case PluginManifestError.unknownKey = $0 else {
                return XCTFail("expected unknownKey, got \($0)")
            }
        }
    }

    func testRejectsMissingEntry() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), writeSidecar: false)) {
            guard case PluginManifestError.entryNotExecutable = $0 else {
                return XCTFail("expected entryNotExecutable, got \($0)")
            }
        }
    }

    func testRejectsNonExecutableEntry() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), executable: false)) {
            guard case PluginManifestError.entryNotExecutable = $0 else {
                return XCTFail("expected entryNotExecutable, got \($0)")
            }
        }
    }

    func testRejectsEntryOutsideRoot() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), manifest: ["entry": "../outside.sh"])) {
            guard case PluginManifestError.invalidField(let field) = $0 else {
                return XCTFail("expected invalidField, got \($0)")
            }
            XCTAssertEqual(field, "entry")
        }
    }

    func testRejectsWrongProtocolVersion() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), manifest: ["protocolVersion": 99])) {
            guard case PluginManifestError.unsupportedProtocolVersion(let version) = $0 else {
                return XCTFail("expected unsupportedProtocolVersion, got \($0)")
            }
            XCTAssertEqual(version, 99)
        }
    }

    func testRejectsWrongSchemaVersion() throws {
        XCTAssertThrowsError(try StubPlugin.write(at: plugin(), manifest: ["schemaVersion": 0])) {
            guard case PluginManifestError.unsupportedSchemaVersion = $0 else {
                return XCTFail("expected unsupportedSchemaVersion, got \($0)")
            }
        }
    }

    func testRejectsBadIdentifier() throws {
        for (index, id) in ["UPPER", "nodots", "", "-leading"].enumerated() {
            XCTAssertThrowsError(try StubPlugin.write(at: plugin("bad-\(index)"), manifest: ["id": id])) {
                guard case PluginManifestError.invalidPluginID(let rejected) = $0 else {
                    return XCTFail("expected invalidPluginID for \(id), got \($0)")
                }
                XCTAssertEqual(rejected, id)
            }
        }
    }

    func testRejectsInvalidJSON() throws {
        let folder = plugin()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "not json".write(
            to: folder.appendingPathComponent(PluginManifest.fileName), atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try PluginManifest.load(at: folder)) {
            guard case PluginManifestError.invalidJSON = $0 else {
                return XCTFail("expected invalidJSON, got \($0)")
            }
        }
        XCTAssertThrowsError(try PluginManifest.load(at: plugin("absent"))) {
            guard case PluginManifestError.unreadableManifest = $0 else {
                return XCTFail("expected unreadableManifest, got \($0)")
            }
        }
    }
}
