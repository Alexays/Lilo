import XCTest
@testable import Lilo

@MainActor
final class StartupMetricsExportTests: XCTestCase {
    // The report headlines Boot + First Content Finished and labels the latest mark as a session
    // mark, so a user navigation long after boot never reads as cold-start time.
    func testExportHeadlinesColdStartAndLabelsSessionMark() {
        StartupMetrics.mark("chromeVisualReady")
        StartupMetrics.mark("firstContentFinished")
        StartupMetrics.mark("firstContentLoadRequested")  // a late, session-lifetime mark

        let text = StartupMetrics.exportText()

        XCTAssertTrue(
            text.contains("Boot (chrome visual ready):"),
            "Boot headline should be present and clearly the chrome-visual-ready figure"
        )
        XCTAssertTrue(
            text.contains("First Content Finished:"),
            "Time-to-usable-page should be reported separately from boot"
        )
        XCTAssertTrue(
            text.contains("Last session mark:"),
            "The most recent mark must be labelled as a session mark, not boot time"
        )
    }

    // A chrome mark reaches the host late; dated by the chrome, it lands at its own time, between
    // the native marks recorded around it, and the deltas on both sides follow.
    func testLateChromeMarkLandsAtTheTimeItHappened() throws {
        StartupMetrics.mark("lateTestBefore")
        usleep(10_000)
        let chromeTime = Date().timeIntervalSince1970 * 1000
        usleep(10_000)
        StartupMetrics.mark("lateTestAfter")
        StartupMetrics.mark("lateTestChrome", occurredAt: chromeTime)

        let marks = try XCTUnwrap(StartupMetrics.bridgeSnapshot()["marks"] as? [[String: Any]])
        let events = marks.map { $0["event"] as? String ?? "" }
        let index = try XCTUnwrap(events.lastIndex(of: "lateTestChrome"))
        XCTAssertEqual(Array(events[(index - 1)...(index + 1)]), ["lateTestBefore", "lateTestChrome", "lateTestAfter"])

        let total = { (i: Int) in marks[i]["totalMilliseconds"] as? Double ?? -1 }
        let delta = { (i: Int) in marks[i]["deltaMilliseconds"] as? Double ?? -1 }
        XCTAssertEqual(delta(index), total(index) - total(index - 1), accuracy: 0.01)
        XCTAssertEqual(delta(index + 1), total(index + 1) - total(index), accuracy: 0.01)
        XCTAssertGreaterThan(delta(index), 5)
        XCTAssertGreaterThan(delta(index + 1), 5)
    }
}
