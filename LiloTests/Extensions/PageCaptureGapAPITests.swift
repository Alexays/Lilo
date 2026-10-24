import AppKit
import WebKit
import XCTest
@testable import Lilo

/// chrome.pageCapture on a real tab through the real gap router.
@MainActor
final class PageCaptureGapAPITests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var registry: ProfileExtensionRegistry!
    private var router: GapBridgeRouter!
    private var extensionId: String!
    private var directory: URL!
    private var server: TinyHTTPServer!

    /// A 1x1 transparent PNG.
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        registry = try context.profileContexts.context(for: profileId).extensions
        window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        let nsWindow = try XCTUnwrap(window.window)
        nsWindow.alphaValue = 0
        nsWindow.orderFrontRegardless()
        nsWindow.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 700), display: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        try XCTUnwrap(nsWindow.contentView).addSubview(container)
        window.contentContainerView = container
        context.windows.add(window)
        window.switchToSpace(space.id)
        window.setupExtensions()
        router = context.engineFactory.gapRouter

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("page-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Capture", "version": "1.0", "permissions": ["pageCapture"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try await registry.load(from: directory)
        extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let png = Self.png
        server = try await TinyHTTPServer { request in
            request.hasPrefix("GET /dot.png ")
                ? ("200 OK", ["Content-Type: image/png"], png)
                : ("200 OK", ["Content-Type: text/html; charset=utf-8"], Data("<title>Caf\u{E9}</title><p>caf\u{E9} = ok</p><img src=\"/dot.png\">".utf8))
        }
    }

    override func tearDown() async throws {
        server = nil
        window.window?.close()
        window = nil
        registry = nil
        router = nil
        browserContext.tearDown()
        browserContext = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func capture(_ position: [String: Int]) async -> (result: Any?, error: String?) {
        await router.route(namespace: "pageCapture", method: "saveAsMHTML", params: ["tab": position], extensionId: extensionId, fromWorker: true, registry: registry)
    }

    /// Opens `url` in a new tab, loaded, and returns its position.
    private func openTab(_ url: URL, isLoaded: @escaping (WKWebViewTab) -> Bool) async throws -> [String: Int] {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: url))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        let loaded = await pollUntil(timeout: 10) { isLoaded(engine) && !engine.wkWebView.isLoading }
        XCTAssertTrue(loaded, "the page loads")
        let adapter = try XCTUnwrap(window.tabManager.tabAdapter(for: tab.id))
        return try XCTUnwrap(registry.tabPosition(of: adapter, extensionId: extensionId))
    }

    func testSavesTheTabAsASCIIMHTMLWithItsSubresources() async throws {
        let page = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        let position = try await openTab(page) { $0.currentTitle == "Caf\u{E9}" }
        let (result, error) = await capture(position)
        XCTAssertNil(error)
        let mhtml = try XCTUnwrap(result as? String)

        XCTAssertTrue(mhtml.allSatisfy(\.isASCII), "every part is encoded")
        let head = try XCTUnwrap(mhtml.components(separatedBy: "\r\n\r\n").first)
        XCTAssertEqual(
            head.split(separator: "\r\n").compactMap { $0.first == "\t" ? nil : $0.split(separator: ":").first.map(String.init) },
            ["From", "Snapshot-Content-Location", "Subject", "Date", "MIME-Version", "Content-Type"]
        )
        XCTAssertTrue(head.contains("Snapshot-Content-Location: \(page.absoluteString)\r\n"))
        XCTAssertTrue(head.contains("Subject: =?utf-8?B?\(Data("Caf\u{E9}".utf8).base64EncodedString())?=\r\n"))
        let boundary = try XCTUnwrap(head.firstMatch(of: /boundary="([^"]+)"/)?.1)
        let parts = mhtml.components(separatedBy: "--\(boundary)")
        XCTAssertEqual(parts.last, "--\r\n", "the document ends with the closing boundary")

        let html = try XCTUnwrap(parts.first { $0.contains("\r\nContent-Location: \(page.absoluteString)\r\n") })
        XCTAssertTrue(html.contains("Content-Type: text/html"))
        XCTAssertTrue(html.contains("Content-Transfer-Encoding: quoted-printable"))
        XCTAssertTrue(html.contains("caf=C3=A9 =3D ok"), "text is quoted-printable")
        let image = try XCTUnwrap(parts.first { $0.contains("Content-Location: \(page.absoluteString)dot.png\r\n") })
        XCTAssertTrue(image.contains("Content-Type: image/png\r\nContent-Transfer-Encoding: base64\r\n"))
        XCTAssertTrue(image.contains(Self.png.base64EncodedString(options: .lineLength76Characters)), "base64 lines of 76 characters")
    }

    func testAnOptionalPageCaptureIsGrantedAtThePromptUntilUninstalled() async throws {
        let optional = directory.appendingPathComponent("optional", isDirectory: true)
        try FileManager.default.createDirectory(at: optional, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Optional", "version": "1.0", "optional_permissions": ["pageCapture"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: optional.appendingPathComponent("manifest.json"))
        try await registry.load(from: optional)
        let id = try XCTUnwrap(registry.loadedExtensions.first { $0.id != extensionId }?.id)
        let route = { (method: String, params: [String: Any]) in
            await self.router.route(namespace: "permissions", method: method, params: params, extensionId: id, fromWorker: true, registry: self.registry)
        }
        let capture = { await self.router.route(namespace: "pageCapture", method: "saveAsMHTML", params: ["tab": ["windowPosition": 0, "index": 99]], extensionId: id, fromWorker: true, registry: self.registry) }
        let refused = await capture()
        XCTAssertEqual(refused.error, "Permission 'pageCapture' is required for pageCapture.saveAsMHTML")
        let undeclared = await route("request", ["permissions": ["debugger"]])
        XCTAssertEqual(undeclared.error, "Only permissions specified in the manifest may be requested.")

        // Declined, then allowed at the prompt.
        for allow in [false, true] {
            let request = Task { await route("request", ["permissions": ["pageCapture"]]) }
            let prompted = await pollUntil(timeout: 5) { !self.registry.pendingPermissionRequests.isEmpty }
            XCTAssertTrue(prompted, "the request prompts")
            registry.resolvePermissionRequest(id: try XCTUnwrap(registry.pendingPermissionRequests.keys.first), granted: allow)
            let answer = await request.value
            XCTAssertEqual(answer.result as? Bool, allow)
        }
        let held = await route("held", [:])
        XCTAssertEqual(held.result as? [String], ["pageCapture"])
        let granted = await capture()
        XCTAssertEqual(granted.error, "Cannot find the tab for this request.", "the grant lets the call through")
        let again = await route("request", ["permissions": ["pageCapture"]])
        XCTAssertEqual(again.result as? Bool, true, "a held permission is granted without a prompt")
        XCTAssertTrue(registry.pendingPermissionRequests.isEmpty)

        // Kept across a reload, gone with an uninstall.
        let stored = try await registry.extensionStorage.loadAccessStates()
        XCTAssertEqual(stored[id]?.gapPermissions, ["pageCapture"])
        await registry.disable(extensionId: id)
        try await registry.enable(extensionId: id)
        XCTAssertEqual(registry.heldPermissions(of: id), ["pageCapture"])
        await registry.unload(extensionId: id)
        let states = try await registry.extensionStorage.loadAccessStates()
        XCTAssertNil(states[id])
    }

    func testRefusesWhatChromeRefuses() async throws {
        let blank = try await openTab(try XCTUnwrap(URL(string: "about:blank"))) { _ in true }
        let refused = await capture(blank)
        XCTAssertEqual(refused.error, "Don't have permissions required to capture this page.")
        let missing = await capture(["windowPosition": 0, "index": 99])
        XCTAssertEqual(missing.error, "Cannot find the tab for this request.")
    }
}
