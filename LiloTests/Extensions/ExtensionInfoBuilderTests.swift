import XCTest
import WebKit
@testable import Lilo

@MainActor
final class ExtensionInfoBuilderTests: XCTestCase {

    // MARK: - Tests

    func testBuildMapsManifestIcons() {
        let manifest: [String: Any] = [
            "name": "Test",
            "version": "1.0.0",
            "icons": [
                "16": "images/icon16.png",
                "128": "images/icon128.png",
                "48": "images/icon48.png"
            ]
        ]

        let icons = ExtensionInfoBuilder.buildFromManifest(manifest: manifest, id: "ext-id").icons

        XCTAssertEqual(icons.count, 3)
        XCTAssert(icons.contains { $0.size == 16 && $0.url == "images/icon16.png" })
        XCTAssert(icons.contains { $0.size == 128 && $0.url == "images/icon128.png" })
        XCTAssert(icons.contains { $0.size == 48 && $0.url == "images/icon48.png" })
    }

    func testBuildSkipsManifestIconsWithInvalidSize() {
        let manifest: [String: Any] = [
            "name": "Test",
            "version": "1.0.0",
            "icons": [
                "128": "images/icon128.png",
                "invalid": "images/invalid.png"
            ]
        ]

        let icons = ExtensionInfoBuilder.buildFromManifest(manifest: manifest, id: "ext-id").icons

        XCTAssertEqual(icons.count, 1)
        XCTAssertEqual(icons.first?.size, 128)
    }

    func testBuildWithManifestData() {
        let manifest: [String: Any] = [
            "name": "My Extension",
            "version": "2.0.0",
            "description": "An awesome extension",
            "permissions": ["storage", "tabs"],
            "host_permissions": ["*://*.example.com/*"],
            "icons": [
                "128": "images/icon128.png"
            ]
        ]

        let info = ExtensionInfoBuilder.buildFromManifest(
            manifest: manifest,
            id: "ext-123",
            enabled: true,
            installType: "development"
        )

        XCTAssertEqual(info.id, "ext-123")
        XCTAssertEqual(info.name, "My Extension")
        XCTAssertEqual(info.version, "2.0.0")
        XCTAssertEqual(info.description, "An awesome extension")
        XCTAssertEqual(info.enabled, true)
        XCTAssertEqual(info.installType, "development")
        XCTAssertEqual(info.permissions, ["storage", "tabs"])
        XCTAssertEqual(info.hostPermissions, ["*://*.example.com/*"])
        XCTAssertEqual(info.icons.count, 1)
    }

    func testBuildWithDefaults() {
        let manifest: [String: Any] = [
            "name": "Minimal Extension",
            "version": "1.0.0"
        ]

        let info = ExtensionInfoBuilder.buildFromManifest(
            manifest: manifest,
            id: "minimal-123"
        )

        XCTAssertEqual(info.id, "minimal-123")
        XCTAssertEqual(info.enabled, true) // default
        XCTAssertEqual(info.installType, "normal") // default
        XCTAssertEqual(info.type, "extension") // default
        XCTAssertEqual(info.permissions.count, 0)
        XCTAssertEqual(info.hostPermissions.count, 0)
        XCTAssertEqual(info.icons.count, 0)
        XCTAssertEqual(info.offlineEnabled, false) // default
        XCTAssertEqual(info.disableReasons.count, 0) // default
    }

    func testBuildSortsManifestIconsBySize() {
        let manifest: [String: Any] = [
            "name": "Test",
            "version": "1.0.0",
            "icons": [
                "128": "images/icon128.png",
                "16": "images/icon16.png",
                "48": "images/icon48.png"
            ]
        ]

        let icons = ExtensionInfoBuilder.buildFromManifest(manifest: manifest, id: "ext-id").icons

        XCTAssertEqual(icons.count, 3)
        XCTAssertEqual(icons[0].size, 16)
        XCTAssertEqual(icons[1].size, 48)
        XCTAssertEqual(icons[2].size, 128)
    }
}
