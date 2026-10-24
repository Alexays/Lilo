import WebKit
import XCTest
@testable import Lilo

/// "Ask where to save each file": the choice decides where a real WebKit download lands, or stops it.
@MainActor
final class DownloadDestinationChoiceTests: XCTestCase {
    private var db: TemporaryProfileDatabase!
    private var manager: DownloadManager!
    private var folder: URL!
    /// Hosts the downloads: a WKDownload dies with its web view.
    private let webView = WKWebView(frame: .zero)

    override func setUp() async throws {
        db = try TemporaryProfileDatabase()
        manager = DownloadManager(dockController: nil)
        manager.setStore(DownloadStore(dbPool: db.pool))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manager.downloadsFolderProvider = { [folder] in folder }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        manager = nil
        db.tearDown()
        db = nil
    }

    /// Hands the download over in WebKit's callback, as the app does: past it, WebKit may already have
    /// asked the download, still without a delegate, for its destination.
    private func startDownload() {
        let request = URLRequest(url: URL(string: "data:text/plain;base64,aGVsbG8=")!)
        webView.startDownload(using: request) { download in self.manager.startDownload(download) }
    }

    func testTheChosenFileReceivesTheDownload() async throws {
        let chosen = folder.appendingPathComponent("picked.txt")
        var proposed: URL?
        manager.chooseDestination = { url, _ in proposed = url; return chosen }

        startDownload()

        let landed = await pollUntil { FileManager.default.fileExists(atPath: chosen.path) }
        XCTAssertTrue(landed)
        XCTAssertEqual(proposed?.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL,
                       "the panel opens on the downloads folder")
    }

    func testCancelingTheChoiceSavesNothing() async throws {
        var asked = false
        manager.chooseDestination = { _, _ in asked = true; return nil }

        startDownload()

        _ = await pollUntil { asked }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(asked)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}
