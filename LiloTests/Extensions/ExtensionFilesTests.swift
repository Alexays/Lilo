import XCTest
@testable import Lilo

/// The profile's folder of installed extension copies: updates swap atomically and roll back.
@MainActor
final class ExtensionFilesTests: XCTestCase {
    private var root: URL!
    private var files: ExtensionFiles!
    private let extensionId = "abcdefghijklmnopabcdefghijklmnop"

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-files-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(extensionId), withIntermediateDirectories: true)
        try "old".write(to: directory.appendingPathComponent("\(extensionId)/version.txt"), atomically: true, encoding: .utf8)
        files = ExtensionFiles(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func package(_ version: String) throws -> URL {
        let url = root.appendingPathComponent("package-\(version)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try version.write(to: url.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        return url
    }

    private func installedVersion() throws -> String {
        try String(contentsOf: files.directory!.appendingPathComponent("\(extensionId)/version.txt"), encoding: .utf8)
    }

    func testReplaceSwapsInTheNewCopyAndLeavesNoBackup() async throws {
        var installed: URL?
        try await files.replace(extensionId, with: try package("new"), beforeSwap: {}, install: { installed = $0 }, rollback: { _ in })

        XCTAssertEqual(try installedVersion(), "new")
        XCTAssertEqual(installed?.lastPathComponent, extensionId)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.directory!.path), [extensionId])
    }

    func testAFailedInstallPutsThePreviousCopyBack() async throws {
        struct LoadFailed: Error {}
        var rolledBack = false

        do {
            try await files.replace(extensionId, with: try package("broken"), beforeSwap: {}, install: { _ in throw LoadFailed() }, rollback: { _ in rolledBack = true })
            XCTFail("the install error is rethrown")
        } catch is LoadFailed {}

        XCTAssertEqual(try installedVersion(), "old")
        XCTAssertTrue(rolledBack)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.directory!.path), [extensionId])
    }

    func testSweepPutsBackAnUpdateBackupWhoseCopyIsMissing() throws {
        let directory = files.directory!
        try FileManager.default.moveItem(at: directory.appendingPathComponent(extensionId), to: directory.appendingPathComponent(".\(extensionId).update-bak"))

        files.sweep(keeping: [extensionId])

        XCTAssertEqual(try installedVersion(), "old")
    }

    /// An unpacked folder loads from a clone Lilo may write into, kept until a file of the folder changes.
    func testAnUnpackedFolderLoadsFromAClonePreparedApartFromIt() throws {
        let folder = try package("1")
        let copy = try files.workingCopy(of: folder)
        XCTAssertNotEqual(copy.path, folder.path)
        XCTAssertFalse(files.owns(copy.path), "a clone is never taken for a store copy")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("version.txt"), encoding: .utf8), "1")

        try "prepared".write(to: copy.appendingPathComponent("lilo.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("lilo.txt").path), "the developer's folder is never written")
        XCTAssertEqual(try files.workingCopy(of: folder), copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("lilo.txt").path), "an unchanged folder keeps its prepared clone")

        try "10".write(to: folder.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try files.workingCopy(of: folder), copy)
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("version.txt"), encoding: .utf8), "10")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("lilo.txt").path), "a changed folder is cloned again")

        files.remove(folder.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("version.txt").path))
        XCTAssertEqual(try files.workingCopy(of: files.directory!.appendingPathComponent(extensionId)), files.directory!.appendingPathComponent(extensionId))
    }
}
