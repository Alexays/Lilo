import XCTest
@testable import Lilo

final class DownloadItemTests: XCTestCase {
    func testBridgeDataContainsAllFields() {
        var item = DownloadItem(
            id: nil,
            url: "https://example.com/file.zip",
            filename: "file.zip",
            destinationPath: "/Downloads/file.zip",
            bytesReceived: 1024,
            totalBytes: 4096,
            state: .inProgress,
            startedAt: Date(timeIntervalSince1970: 1000),
            fileMissing: false
        )
        item.id = 42

        let data = item.bridgeData
        XCTAssertEqual(data["id"] as? Int64, 42)
        XCTAssertEqual(data["url"] as? String, "https://example.com/file.zip")
        XCTAssertEqual(data["filename"] as? String, "file.zip")
        XCTAssertEqual(data["state"] as? String, "inProgress")
        XCTAssertEqual(data["bytesReceived"] as? Int64, 1024)
        XCTAssertEqual(data["totalBytes"] as? Int64, 4096)
        XCTAssertEqual(data["fileMissing"] as? Bool, false)
        XCTAssertNil(data["error"])
        XCTAssertNil(data["destinationPath"])
    }

    func testBridgeDataIncludesOptionalFields() {
        var item = DownloadItem(
            id: 1,
            url: "https://example.com/f.pdf",
            filename: "f.pdf",
            destinationPath: "/Downloads/f.pdf",
            bytesReceived: 0,
            totalBytes: -1,
            state: .interrupted,
            startedAt: Date(),
            fileMissing: false
        )
        item.error = "Network error"
        item.endedAt = Date(timeIntervalSince1970: 2000)

        let data = item.bridgeData
        XCTAssertEqual(data["error"] as? String, "Network error")
        XCTAssertEqual(data["endedAt"] as? TimeInterval, 2000.0)
    }

    func testDownloadStateRawValues() {
        XCTAssertEqual(DownloadState.inProgress.rawValue, "inProgress")
        XCTAssertEqual(DownloadState.paused.rawValue, "paused")
        XCTAssertEqual(DownloadState.complete.rawValue, "complete")
        XCTAssertEqual(DownloadState.interrupted.rawValue, "interrupted")
    }
}
