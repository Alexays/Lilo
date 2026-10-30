import WebKit
import XCTest
@testable import Lilo

/// "Ask where to save each file": the choice decides where a real WebKit download lands, or stops it.
@MainActor
final class DownloadDestinationChoiceTests: XCTestCase {
    private var db: TemporaryProfileDatabase!
    private var manager: DownloadManager!
    private var store: DownloadStore!
    private var folder: URL!
    /// Hosts the downloads: a WKDownload dies with its web view.
    private let webView = WKWebView(frame: .zero)

    override func setUp() async throws {
        db = try TemporaryProfileDatabase()
        manager = DownloadManager(dockController: nil)
        store = DownloadStore(dbPool: db.pool)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manager.downloadsFolderProvider = { [folder] in folder }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        manager = nil
        store = nil
        db.tearDown()
        db = nil
    }

    /// Hands the download over in WebKit's callback, as the app does: past it, WebKit may already have
    /// asked the download, still without a delegate, for its destination.
    private func startDownload(privateSpaceId: UUID? = nil) {
        let request = URLRequest(url: URL(string: "data:text/plain;base64,aGVsbG8=")!)
        webView.startDownload(using: request) { download in self.manager.startDownload(download, in: self.store, privateSpaceId: privateSpaceId) }
    }

    func testTheChosenFileReceivesTheDownload() async throws {
        let chosen = folder.appendingPathComponent("picked.txt")
        var proposed: URL?
        manager.chooseDestination = { url, _, _ in proposed = url; return chosen }

        startDownload()

        let landed = await pollUntil { FileManager.default.fileExists(atPath: chosen.path) }
        XCTAssertTrue(landed)
        XCTAssertEqual(proposed?.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL,
                       "the panel opens on the downloads folder")
    }

    func testCancelingTheChoiceSavesNothing() async throws {
        var asked = false
        manager.chooseDestination = { _, _, _ in asked = true; return nil }

        startDownload()

        _ = await pollUntil { asked }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(asked)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testAnExtensionsSuggestionMovesTheDownloadIntoASubfolder() async throws {
        let suggested = folder.appendingPathComponent("sorted/hello.txt")
        manager.suggestFilename = { _ in (filename: "sorted/hello.txt", conflictAction: "uniquify") }

        startDownload()

        let landed = await pollUntil { FileManager.default.fileExists(atPath: suggested.path) }
        XCTAssertTrue(landed)
    }

    func testAPrivateSpaceDownloadAsksNoExtension() async throws {
        var asked = false
        manager.suggestFilename = { _ in asked = true; return (filename: "sorted/hello.txt", conflictAction: "uniquify") }

        startDownload(privateSpaceId: UUID())

        let landed = await pollUntil { (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == false }
        XCTAssertTrue(landed)
        XCTAssertFalse(asked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sorted").path))
    }
}
