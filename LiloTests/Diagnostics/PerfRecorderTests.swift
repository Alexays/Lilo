import XCTest
@testable import Lilo

@MainActor
final class PerfRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PerfRecorderTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if PerfRecorder.isRecording { _ = await PerfRecorder.stop(writingTo: directory) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ body: () async -> Void) async throws -> [String: Any] {
        PerfRecorder.start(processes: { [] }, context: ["tabs": 3], onLimit: {})
        await body()
        let written = await PerfRecorder.stop(writingTo: directory)
        let url = try XCTUnwrap(written)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func events(_ trace: [String: Any], named name: String) -> [[String: Any]] {
        (trace["traceEvents"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == name }
    }

    func testRecordsIntervalsEventsAndContext() async throws {
        let trace = try await record {
            let load = PerfSignposts.navigation.beginInterval("load", id: PerfSignposts.navigation.makeSignpostID())
            PerfSignposts.energy.emitEvent("sessionSave", "written: 2 spaces")
            PerfSignposts.navigation.endInterval("load", load, "finish")
            await Task.detached { PerfSignposts.energy.emitEvent("workerWake", "abcdefghijklmnop") }.value
            _ = PerfSignposts.bridge.beginInterval("handle", id: PerfSignposts.bridge.makeSignpostID(), "createTab")
        }

        let load = try XCTUnwrap(events(trace, named: "load").first)
        XCTAssertEqual(load["ph"] as? String, "X")
        XCTAssertEqual(load["cat"] as? String, "navigation")
        XCTAssertGreaterThanOrEqual(load["dur"] as? Double ?? -1, 0)
        XCTAssertEqual((load["args"] as? [String: Any])?["result"] as? String, "finish")
        XCTAssertEqual((load["args"] as? [String: Any])?["tab"] as? Int, 1)

        let save = try XCTUnwrap(events(trace, named: "sessionSave").first)
        XCTAssertEqual(save["ph"] as? String, "i")
        XCTAssertEqual(save["tid"] as? Int, 1)
        XCTAssertEqual((save["args"] as? [String: Any])?["detail"] as? String, "written: 2 spaces")
        XCTAssertEqual(events(trace, named: "workerWake").first?["tid"] as? Int, 2)

        let unfinished = try XCTUnwrap(events(trace, named: "handle").first)
        XCTAssertEqual(unfinished["ph"] as? String, "B")
        XCTAssertEqual((unfinished["args"] as? [String: Any])?["detail"] as? String, "createTab")

        XCTAssertEqual(events(trace, named: "process_name").first?["args"] as? [String: String], ["name": "Lilo"])
        let metadata = try XCTUnwrap(trace["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["tabs"] as? Int, 3)
        XCTAssertEqual(metadata["droppedEvents"] as? Int, 0)
    }

    func testSignpostsOutsideARecordingAreNotKept() async throws {
        PerfSignposts.energy.emitEvent("before")
        let trace = try await record {}
        PerfSignposts.energy.emitEvent("after")

        XCTAssertFalse(PerfRecorder.isRecording)
        XCTAssertTrue(events(trace, named: "before").isEmpty)
        XCTAssertTrue(events(trace, named: "after").isEmpty)
    }

    func testRecordsAMainThreadHang() async throws {
        let trace = try await record {
            // Lets the run loop wake the observer, then blocks the pass past the hang threshold.
            try? await Task.sleep(for: .milliseconds(20))
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    usleep(150_000)
                    continuation.resume()
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let hang = try XCTUnwrap(events(trace, named: "hang").first)
        XCTAssertEqual(hang["ph"] as? String, "X")
        XCTAssertGreaterThanOrEqual(hang["dur"] as? Double ?? 0, 150_000)
    }

    func testEscapesDetailsIntoValidJSON() async throws {
        let trace = try await record {
            PerfSignposts.energy.emitEvent("git", "quote \" backslash \\ newline \n tab \t")
        }

        let git = try XCTUnwrap(events(trace, named: "git").first)
        XCTAssertEqual((git["args"] as? [String: Any])?["detail"] as? String, "quote \" backslash \\ newline \n tab \t")
    }
}
