import AppKit
import WebKit
import XCTest
@testable import Lilo

/// A tab whose only navigation becomes a download closes when a page opened it, never when the user typed the URL.
@MainActor
final class DownloadTabClosingTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var server: TinyHTTPServer!
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        controller = makeTestWindow(context, showing: space.id)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        context.downloadManager.downloadsFolderProvider = { [folder] in folder }
        server = try await TinyHTTPServer { _ in
            ("200 OK", ["Content-Type: application/zip", #"Content-Disposition: attachment; filename="file.zip""#], Data("zip".utf8))
        }
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var fileURL: URL { URL(string: "http://127.0.0.1:\(server.port)/file.zip")! }

    /// Waits for the download's row, then for the main queue turn the tab closing is deferred to.
    private func awaitDownloadStart() async {
        var started = false
        let token = browserContext.context.downloadManager.addObserver { _ in started = true }
        defer { browserContext.context.downloadManager.removeObserver(token) }
        _ = await pollUntil(timeout: 60) { started }
        await Task.yield()
        _ = await pollUntil(timeout: 1) { false }
    }

    func testABlankTabTheUserTypedADownloadURLIntoStaysOpen() async throws {
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        try XCTUnwrap(controller.tabManager.engineTab(for: tab.id)).loadURL(fileURL)

        await awaitDownloadStart()

        XCTAssertTrue(controller.tabManager.openTabs.contains { $0.id == tab.id })
    }

    func testATabAPageOpenedForADownloadCloses() async throws {
        let opener = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id))
        let tabs = controller.tabManager.openTabs.count

        controller.tab(engine, didCreateNewTab: fileURL, inBackground: false)
        await awaitDownloadStart()

        XCTAssertEqual(controller.tabManager.openTabs.count, tabs)
    }

    func testATargetBlankTabForADownloadCloses() async throws {
        let opener = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id))
        let tabs = controller.tabManager.openTabs.count

        let popup = try XCTUnwrap(controller.createPopupWebView(configuration: engine.wkWebView.configuration, requestedURL: fileURL))
        popup.load(URLRequest(url: fileURL))
        await awaitDownloadStart()

        XCTAssertEqual(controller.tabManager.openTabs.count, tabs)
    }
}
