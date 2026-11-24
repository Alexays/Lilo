import XCTest
@testable import PluginCore
import TestingSupport

/// The coordinate adapter against a stub `coordinate` script (never the real daemon), and the
/// in-process fallback on a `ManualClock`.
final class PluginSchedulerTests: XCTestCase {
    private var root: URL!
    private var stub: URL { root.appendingPathComponent("bin/coordinate") }
    private var log: URL { root.appendingPathComponent("calls.log") }
    private var spool: URL { root.appendingPathComponent("spool", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-plugin-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        // One call per line, arguments joined by a unit separator; `enqueue` answers a fresh id.
        let script = """
        #!/bin/sh
        IFS=$(printf '\\037'); printf '%s\\n' "$*" >> "\(log.path)"
        if [ "$1" = enqueue ]; then
            n=$(cat "\(root.path)/next" 2>/dev/null || echo 1); echo $((n + 1)) > "\(root.path)/next"; echo $n
        fi
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func calls() -> [[String]] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init) }
    }

    private func makeScheduler() -> CoordinatePluginScheduler {
        CoordinatePluginScheduler(executable: stub, spool: spool)
    }

    // MARK: - Locator

    func testLocatorFindsTheBinaryOnPathAndInKnownDirectories() throws {
        XCTAssertEqual(CoordinateLocator.locate(path: "/nonexistent:\(root.path)/bin", home: root)?.path, stub.path)
        XCTAssertNil(CoordinateLocator.locate(path: "/nonexistent", home: root))

        let local = root.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: stub, to: local.appendingPathComponent("coordinate"))
        XCTAssertEqual(CoordinateLocator.locate(path: "", home: root)?.path, local.appendingPathComponent("coordinate").path)
    }

    // MARK: - Coordinate adapter

    func testScheduleEnqueuesARunAtMarkerJob() throws {
        let scheduler = makeScheduler()
        scheduler.schedule("job 1", after: 89.2) { _ in }
        scheduler.flush()

        let call = try XCTUnwrap(calls().first)
        XCTAssertEqual(Array(call.prefix(6)), ["enqueue", "--run-at", "90s", "--repo", "", "--"])
        XCTAssertEqual(Array(call.dropFirst(6)), [
            "sh", "-c", #"mkdir -p "$1" && : > "$1/$2""#, "sh", spool.appendingPathComponent("fired").path, "job%201"
        ])
        XCTAssertEqual(try String(contentsOf: spool.appendingPathComponent("armed/job%201"), encoding: .utf8), "1")
    }

    func testReArmingAndCancelCancelThePreviousCoordinateJob() throws {
        let scheduler = makeScheduler()
        scheduler.schedule("a", after: 60) { _ in }
        scheduler.schedule("a", after: 120) { _ in }
        scheduler.flush()
        XCTAssertEqual(calls().map(\.[0]), ["enqueue", "cancel", "enqueue"])
        XCTAssertEqual(calls()[1], ["cancel", "1"])

        scheduler.cancel("a")
        scheduler.flush()
        XCTAssertEqual(calls().last, ["cancel", "2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.appendingPathComponent("armed/a").path))
    }

    func testAFiredMarkerIsDeliveredLiveAndAfterARestart() async throws {
        let scheduler = makeScheduler()
        scheduler.schedule("live", after: 1) { _ in }
        scheduler.flush()

        let live = expectation(description: "live fire")
        scheduler.resume { id in if id == "live" { live.fulfill() } }
        scheduler.flush()
        try markFired("live")
        await fulfillment(of: [live], timeout: 5)
        scheduler.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.appendingPathComponent("armed/live").path))
        scheduler.suspend()

        // Fired while Lilo was quit: the next launch's `resume` delivers it.
        try markFired("missed id")
        let missed = expectation(description: "catch-up fire")
        let restarted = makeScheduler()
        restarted.resume { id in if id == "missed id" { missed.fulfill() } }
        await fulfillment(of: [missed], timeout: 5)
        restarted.suspend()
    }

    func testFailedEnqueueRecordsNothing() {
        let scheduler = CoordinatePluginScheduler(executable: stub, spool: spool, run: { _, _ in nil })
        scheduler.schedule("a", after: 5) { _ in }
        scheduler.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.appendingPathComponent("armed/a").path))
    }

    /// Runs the marker command the stub "daemon" would have run.
    private func markFired(_ jobID: String) throws {
        let name = jobID.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_"))!
        let fired = spool.appendingPathComponent("fired", isDirectory: true)
        try FileManager.default.createDirectory(at: fired, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fired.appendingPathComponent(name).path, contents: nil)
    }

    // MARK: - In-process fallback

    func testClockSchedulerFiresOnTheManualClockAndHonorsCancel() async throws {
        let clock = ManualClock()
        let scheduler = ClockPluginScheduler(clock: clock)
        let fired = expectation(description: "fired")
        fired.expectedFulfillmentCount = 1
        scheduler.schedule("a", after: 30) { id in if id == "a" { fired.fulfill() } }
        scheduler.schedule("b", after: 30) { _ in XCTFail("cancelled job fired") }
        while clock.armedCount < 2 { await Task.yield() }
        scheduler.cancel("b")
        clock.advance(by: 29)
        clock.advance(by: 1)
        await fulfillment(of: [fired], timeout: 5)
    }
}
