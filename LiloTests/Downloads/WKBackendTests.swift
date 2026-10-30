import WebKit
import XCTest
@testable import Lilo

final class WKBackendTests: XCTestCase {
    @MainActor
    func testADownloadedFileIsQuarantined() async throws {
        let server = try await TinyHTTPServer { _ in
            ("200 OK", ["Content-Type: application/octet-stream", #"Content-Disposition: attachment; filename="tool.sh""#], Data("echo hi\n".utf8))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try TemporaryProfileDatabase()
        defer { database.tearDown() }
        let store = DownloadStore(dbPool: database.pool)
        let backend = WKBackend()
        backend.store = store
        backend.downloadsFolderProvider = { folder }
        var finished: DownloadItem?
        backend.onUpdated = { if $0.state == .complete || $0.state == .interrupted { finished = $0 } }

        let webView = WKWebView()
        // Tracked in WebKit's callback, as the app does: past it, WebKit may already have asked the
        // download, still without a delegate, for its destination.
        webView.startDownload(using: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))) { backend.startTracking($0) }
        // The download's own end, failed or not. The bound only stops a hang: under parallel test runs
        // WebKit's network process takes more than 10 s to finish even this small download.
        _ = await pollUntil(timeout: 60) { finished != nil }
        withExtendedLifetime((webView, store)) {}

        XCTAssertEqual(finished?.state, .complete, finished?.error ?? "no end reported")
        let file = URL(fileURLWithPath: try XCTUnwrap(finished?.destinationPath))
        XCTAssertTrue(DownloadQuarantine.isQuarantined(file), "Gatekeeper checks the file before it first runs")
    }

    @MainActor
    func testTwoDownloadsOfTheSameNameGetTheirOwnFile() async throws {
        let server = try await TinyHTTPServer { _ in
            ("200 OK", ["Content-Type: text/csv", #"Content-Disposition: attachment; filename="report.csv""#], Data("a,b\n".utf8))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try TemporaryProfileDatabase()
        defer { database.tearDown() }
        let store = DownloadStore(dbPool: database.pool)
        let backend = WKBackend()
        backend.store = store
        backend.downloadsFolderProvider = { folder }
        // Both downloads are deciding at once, as when a save panel or an extension's suggestion is pending.
        var deciding = 0
        backend.chooseDestination = { proposed, _, _ in
            deciding += 1
            _ = await pollUntil(timeout: 60) { deciding == 2 }
            return proposed
        }
        var finished: [DownloadItem] = []
        backend.onUpdated = { if $0.state == .complete || $0.state == .interrupted { finished.append($0) } }

        let webView = WKWebView()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        webView.startDownload(using: URLRequest(url: url)) { backend.startTracking($0) }
        webView.startDownload(using: URLRequest(url: url)) { backend.startTracking($0) }
        _ = await pollUntil(timeout: 60) { finished.count == 2 }
        withExtendedLifetime((webView, store)) {}

        XCTAssertEqual(finished.map(\.state), [.complete, .complete], "\(finished.map(\.error))")
        XCTAssertEqual(Set(finished.map(\.filename)), ["report.csv", "report (1).csv"])
    }

    func testResolveDestinationNoConflict() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let result = WKBackend.resolveDestination(for: "unique_\(UUID().uuidString).zip", in: dir)
        XCTAssertEqual(result.lastPathComponent.hasSuffix(".zip"), true)
    }

    func testResolveDestinationWithExtension() {
        // Create a temp file to simulate conflict
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "conflict_\(UUID().uuidString).pdf"
        let conflictURL = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: conflictURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: conflictURL) }

        let result = WKBackend.resolveDestination(for: name, in: dir)
        XCTAssertTrue(result.lastPathComponent.contains("(1)"))
        XCTAssertTrue(result.lastPathComponent.hasSuffix(".pdf"))
    }

    func testResolveDestinationWithoutExtension() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "noext_\(UUID().uuidString)"
        let conflictURL = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: conflictURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: conflictURL) }

        let result = WKBackend.resolveDestination(for: name, in: dir)
        XCTAssertTrue(result.lastPathComponent.contains("(1)"))
        XCTAssertFalse(result.lastPathComponent.contains("."))
    }

    func testResolveDestinationMultipleConflicts() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "multi_\(UUID().uuidString).zip"
        // Create files: name, name (1).zip
        let url1 = dir.appendingPathComponent(name)
        let base = url1.deletingPathExtension().lastPathComponent
        let url2 = dir.appendingPathComponent("\(base) (1).zip")
        FileManager.default.createFile(atPath: url1.path, contents: Data())
        FileManager.default.createFile(atPath: url2.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let result = WKBackend.resolveDestination(for: name, in: dir)
        XCTAssertTrue(result.lastPathComponent.contains("(2)"))
    }
}
