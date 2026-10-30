import XCTest
@testable import Lilo

final class ConversationCheckpointsTests: XCTestCase {
    private var repository: URL!

    override func setUpWithError() throws {
        repository = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try write("app.swift", "let a = 1\n")
        try write(".gitignore", "build/\n")
        try git("add", ".")
        try git("-c", "user.name=Lilo", "-c", "user.email=lilo@example.com", "commit", "-q", "-m", "initial")
        try write("draft.md", "untracked before\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repository)
    }

    func testRestoreBringsBackFilesAndRemovesTheOnesMadeSince() throws {
        let tree = try XCTUnwrap(ConversationCheckpoints.snapshot(in: repository.path))
        try write("app.swift", "let a = 2\n")
        try write("draft.md", "edited\n")
        try write("Sources/new.swift", "new\n")
        try write("build/out.o", "ignored\n")

        XCTAssertTrue(ConversationCheckpoints.restore(tree, in: repository.path))

        XCTAssertEqual(try read("app.swift"), "let a = 1\n")
        XCTAssertEqual(try read("draft.md"), "untracked before\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent("Sources/new.swift").path))
        // Ignored files are not the project's: a restore leaves them alone.
        XCTAssertEqual(try read("build/out.o"), "ignored\n")
    }

    func testSnapshotLeavesTheUsersIndexAlone() throws {
        try write("staged.txt", "staged\n")
        try git("add", "staged.txt")
        _ = try XCTUnwrap(ConversationCheckpoints.snapshot(in: repository.path))
        let status = GitDiff.run(["status", "--porcelain"], in: repository.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(status.contains("A  staged.txt"))
        XCTAssertTrue(status.contains("?? draft.md"))
    }

    func testRestoreFilePutsBackOneFileOrRemovesANewOne() throws {
        let tree = try XCTUnwrap(ConversationCheckpoints.snapshot(in: repository.path))
        try write("app.swift", "changed\n")
        try write("added.txt", "new\n")

        XCTAssertTrue(ConversationCheckpoints.restoreFile(repository.appendingPathComponent("app.swift").path, from: tree, in: repository.path))
        XCTAssertTrue(ConversationCheckpoints.restoreFile("added.txt", from: tree, in: repository.path))

        XCTAssertEqual(try read("app.swift"), "let a = 1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent("added.txt").path))
        XCTAssertFalse(ConversationCheckpoints.restoreFile("/etc/hosts", from: tree, in: repository.path))
    }

    func testOutsideARepositoryThereIsNoCheckpoint() {
        XCTAssertNil(ConversationCheckpoints.snapshot(in: FileManager.default.temporaryDirectory.appendingPathComponent("lilo-none-\(UUID().uuidString)").path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ path: String, _ content: String) throws {
        let url = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repository
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
