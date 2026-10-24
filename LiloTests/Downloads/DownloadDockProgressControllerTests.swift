import XCTest
@testable import Lilo

final class DownloadDockProgressControllerTests: XCTestCase {

    private func item(bytesReceived: Int64, totalBytes: Int64, state: DownloadState = .inProgress) -> DownloadItem {
        DownloadItem(
            id: nil, url: "https://example.com/x.zip", filename: "x.zip",
            destinationPath: "/tmp/x.zip", bytesReceived: bytesReceived, totalBytes: totalBytes,
            state: state, startedAt: Date(), fileMissing: false
        )
    }

    func testEmptyIsZeroCountAndNilProgress() {
        let (count, progress) = DownloadDockProgressController.aggregate([DownloadItem]())
        XCTAssertEqual(count, 0)
        XCTAssertNil(progress)
    }

    func testAllKnownTotalsAggregatesFraction() {
        let active = [
            item(bytesReceived: 25, totalBytes: 100),
            item(bytesReceived: 75, totalBytes: 100)
        ]
        let (count, progress) = DownloadDockProgressController.aggregate(active)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(progress ?? -1, 100.0 / 200.0, accuracy: 1e-9)
    }

    func testAnyUnknownTotalMakesProgressIndeterminate() {
        let active = [
            item(bytesReceived: 25, totalBytes: 100),
            item(bytesReceived: 10, totalBytes: -1)  // unknown total
        ]
        let (count, progress) = DownloadDockProgressController.aggregate(active)
        XCTAssertEqual(count, 2)
        XCTAssertNil(progress)  // indeterminate: not every download has a known total
    }

    func testZeroTotalIsTreatedAsUnknown() {
        // totalBytes <= 0 is "unknown"; a single known-zero-total download is indeterminate
        let (count, progress) = DownloadDockProgressController.aggregate([item(bytesReceived: 5, totalBytes: 0)])
        XCTAssertEqual(count, 1)
        XCTAssertNil(progress)
    }

    func testPausedDownloadCountsTowardBadge() {
        let active = [
            item(bytesReceived: 50, totalBytes: 100, state: .inProgress),
            item(bytesReceived: 30, totalBytes: 100, state: .paused)
        ]
        let (count, progress) = DownloadDockProgressController.aggregate(active)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(progress ?? -1, 80.0 / 200.0, accuracy: 1e-9)
    }
}
