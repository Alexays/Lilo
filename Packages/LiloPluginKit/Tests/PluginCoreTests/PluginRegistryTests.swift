import XCTest
@testable import PluginCore
import TestingSupport

final class PluginRegistryTests: XCTestCase {
    private var root: URL!
    private var userRoot: URL { root.appendingPathComponent("user", isDirectory: true) }
    private var bundledRoot: URL { root.appendingPathComponent("bundled", isDirectory: true) }
    private var supportRoot: URL { root.appendingPathComponent("support", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-plugin-registry-\(UUID().uuidString)", isDirectory: true)
        for url in [userRoot, bundledRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func registry() -> PluginRegistry {
        PluginRegistry(userRoot: userRoot, bundledRoot: bundledRoot, supportRoot: supportRoot)
    }

    func testScansBothRootsAndRejectsBadManifest() async throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("good"))
        // Invalid JSON in the bundled root: a record with a rejection reason, never a crash.
        let bad = bundledRoot.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try "not json".write(to: bad.appendingPathComponent("lilo-plugin.json"), atomically: true, encoding: .utf8)

        let result = await registry().rescan()
        XCTAssertEqual(result.records.count, 2)
        let good = try XCTUnwrap(result.records.first { $0.id == "app.lilo.test.stub" })
        XCTAssertTrue(good.valid)
        XCTAssertFalse(good.bundled)
        let rejected = try XCTUnwrap(result.records.first { $0.id == "bad" })
        XCTAssertTrue(rejected.bundled)
        XCTAssertNotNil(rejected.rejectionReason)
        XCTAssertNil(rejected.manifest)
    }

    func testUserPluginShadowsBundledWithSameID() async throws {
        try StubPlugin.write(at: bundledRoot.appendingPathComponent("bundled-stub"), manifest: ["title": "Bundled"])
        try StubPlugin.write(at: userRoot.appendingPathComponent("user-stub"), manifest: ["title": "User"])

        let result = await registry().rescan()
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.manifest?.title, "User")
        XCTAssertEqual(result.records.first?.bundled, false)
    }

    func testChangeDetectionOnSecondScan() async throws {
        let folder = userRoot.appendingPathComponent("stub")
        try StubPlugin.write(at: folder)
        let registry = registry()

        let first = await registry.rescan()
        XCTAssertTrue(first.changed)

        let second = await registry.rescan()
        XCTAssertFalse(second.changed)

        // Touch the manifest's mtime: the folder reports changed.
        try "still same".write(
            to: folder.appendingPathComponent("lilo-plugin.json"), atomically: true, encoding: .utf8
        )
        let third = await registry.rescan()
        XCTAssertEqual(third.changedFolders.map(\.lastPathComponent), ["stub"])
        // A record with a now-invalid manifest carries its rejection reason.
        XCTAssertNotNil(third.records.first?.rejectionReason)

        // Deleting the folder reports it changed too.
        try FileManager.default.removeItem(at: folder)
        let fourth = await registry.rescan()
        XCTAssertEqual(fourth.changedFolders.map(\.lastPathComponent), ["stub"])
        XCTAssertTrue(fourth.records.isEmpty)
    }
}
