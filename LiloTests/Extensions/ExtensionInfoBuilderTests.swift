import XCTest
import WebKit
@testable import Lilo

@MainActor
final class ExtensionInfoBuilderTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("info-builder-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        for size in [16, 48, 128] {
            try Data("png\(size)".utf8).write(to: folder.appendingPathComponent("images/icon\(size).png"))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func dataURL(_ text: String) -> String {
        "data:image/png;base64,\(Data(text.utf8).base64EncodedString())"
    }

    // MARK: - Tests

    func testBuildMapsManifestIconsToDataURLs() {
        let manifest: [String: Any] = [
            "name": "Test",
            "version": "1.0.0",
            "icons": [
                "16": "images/icon16.png",
                "128": "/images/icon128.png",
                "48": "images/icon48.png"
            ]
        ]

        let icons = ExtensionInfoBuilder.buildFromManifest(manifest: manifest, id: "ext-id", folder: folder).icons

        XCTAssertEqual(icons.map(\.size), [16, 48, 128])
        XCTAssertEqual(icons.map(\.url), [dataURL("png16"), dataURL("png48"), dataURL("png128")])
    }

    func testBuildSkipsIconsWithInvalidSizeMissingFileOrOutsideTheFolder() throws {
        let outside = "\(folder.lastPathComponent)-outside.png"
        let outsideURL = folder.deletingLastPathComponent().appendingPathComponent(outside)
        try Data("secret".utf8).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let manifest: [String: Any] = [
            "name": "Test",
            "version": "1.0.0",
            "icons": [
                "128": "images/icon128.png",
                "invalid": "images/icon16.png",
                "32": "images/missing.png",
                "64": "../\(outside)"
            ]
        ]

        let icons = ExtensionInfoBuilder.buildFromManifest(manifest: manifest, id: "ext-id", folder: folder).icons

        XCTAssertEqual(icons.map(\.size), [128])
    }

    func testBuildMakesTheOptionsPageAbsolute() {
        let optionsUI: [String: Any] = ["name": "Test", "options_ui": ["page": "/options.html"]]
        let optionsPage: [String: Any] = ["name": "Test", "options_page": "settings/index.html"]

        XCTAssertEqual(
            ExtensionInfoBuilder.buildFromManifest(manifest: optionsUI, id: "ext-id", folder: folder).optionsUrl,
            "chrome-extension://ext-id/options.html"
        )
        XCTAssertEqual(
            ExtensionInfoBuilder.buildFromManifest(manifest: optionsPage, id: "ext-id", folder: folder).optionsUrl,
            "chrome-extension://ext-id/settings/index.html"
        )
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
            folder: folder,
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
            id: "minimal-123",
            folder: folder
        )

        XCTAssertEqual(info.id, "minimal-123")
        XCTAssertEqual(info.enabled, true) // default
        XCTAssertEqual(info.installType, "normal") // default
        XCTAssertEqual(info.type, "extension") // default
        XCTAssertEqual(info.permissions.count, 0)
        XCTAssertEqual(info.hostPermissions.count, 0)
        XCTAssertEqual(info.icons.count, 0)
        XCTAssertNil(info.optionsUrl)
        XCTAssertEqual(info.offlineEnabled, false) // default
        XCTAssertEqual(info.disableReasons.count, 0) // default
    }
}
