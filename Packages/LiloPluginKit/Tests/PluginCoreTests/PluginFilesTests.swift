import XCTest
@testable import PluginCore

final class PluginFilesTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-plugin-files-\(UUID().uuidString)")
        root = base.appendingPathComponent("support", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testWriteReadAndListRoundTrip() throws {
        let files = PluginFiles(root: root)
        try files.write("state/last.json", content: "{\"n\":1}")
        try files.write("notes.txt", content: "hi")
        XCTAssertEqual(try files.read("state/last.json"), "{\"n\":1}")
        XCTAssertEqual(try files.list(), [.init(name: "notes.txt", isDirectory: false), .init(name: "state", isDirectory: true)])
        XCTAssertEqual(try files.list("state"), [.init(name: "last.json", isDirectory: false)])
    }

    func testTraversalAndAbsolutePathsReject() throws {
        let files = PluginFiles(root: root)
        for path in ["../outside/secret.txt", "a/../../outside/secret.txt", outside.appendingPathComponent("secret.txt").path, "a\0b"] {
            XCTAssertThrowsError(try files.read(path), path) { XCTAssertEqual(($0 as? PluginRequestError)?.code, -32602) }
            XCTAssertThrowsError(try files.write(path, content: "x"), path)
        }
        XCTAssertThrowsError(try files.list(".."))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8), "secret")
    }

    func testSymlinkOutOfTheFolderRejects() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let files = PluginFiles(root: root)
        XCTAssertThrowsError(try files.read("link/secret.txt"))
        XCTAssertThrowsError(try files.write("link/new.txt", content: "x"))
        XCTAssertThrowsError(try files.list("link"))
        // An atomic write replaces a dangling link instead of following it out.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("made.txt"))
        try files.write("dangling", content: "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("made.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }

    func testOversizedContentAndFolderWriteReject() throws {
        let files = PluginFiles(root: root)
        XCTAssertThrowsError(try files.write("big.txt", content: String(repeating: "a", count: PluginFiles.maxBytes + 1)))
        XCTAssertThrowsError(try files.write("", content: "x"))
        XCTAssertThrowsError(try files.read("missing.txt"))
    }
}
