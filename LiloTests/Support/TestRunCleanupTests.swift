import Foundation
import XCTest

final class TestRunCleanupTests: XCTestCase {
    /// A run ending while another goes on must leave the other's stores alone: they are open in its
    /// network process, where every IndexedDB open then fails with "Unable to open database file on disk".
    func testARunEndingKeepsTheStoresOfARunStillGoing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("test-run-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("LiloTestRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        // The other run started first: it recorded the baseline and its marker, named by a live pid.
        try "".write(to: runs.appendingPathComponent("baseline"), atomically: true, encoding: .utf8)
        let otherRun = runs.appendingPathComponent("\(getppid())")
        FileManager.default.createFile(atPath: otherRun.path, contents: nil)

        let thisRun = TestRunCleanup(webKitRoot: root)
        thisRun.testBundleWillStart(Bundle(for: Self.self))
        let othersStore = root.appendingPathComponent("WebsiteDataStore/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: othersStore, withIntermediateDirectories: true)
        thisRun.testBundleDidFinish(Bundle(for: Self.self))
        XCTAssertTrue(FileManager.default.fileExists(atPath: othersStore.path), "removed a store another run still uses")

        // The other run, last to end, removes what both created.
        try FileManager.default.removeItem(at: otherRun)
        TestRunCleanup(webKitRoot: root).testBundleDidFinish(Bundle(for: Self.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: othersStore.path))
    }

    /// Under the .tests host, a store a run cut short left behind goes with the next run's own.
    func testTheTestHostRemovesWhatAnInterruptedRunLeft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("test-run-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leftover = root.appendingPathComponent("WebsiteDataStore/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        let run = TestRunCleanup(webKitRoot: root, keepsExisting: false)
        run.testBundleWillStart(Bundle(for: Self.self))
        run.testBundleDidFinish(Bundle(for: Self.self))

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }
}
