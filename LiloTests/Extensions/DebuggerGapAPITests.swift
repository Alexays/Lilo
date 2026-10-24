import AppKit
import WebKit
import XCTest
@testable import Lilo

/// chrome.debugger on a real tab through the real gap router: the tab's Web Inspector speaks CDP.
@MainActor
final class DebuggerGapAPITests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var registry: ProfileExtensionRegistry!
    private var router: GapBridgeRouter!
    private var extensionId: String!
    private var directory: URL!
    private var server: TinyHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        registry = try context.profileContexts.context(for: profileId).extensions
        window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        // Off screen and transparent, as the agent tests do: the page renders, nothing shows.
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

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("debugger-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Debugger", "version": "1.0", "permissions": ["debugger"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try await registry.load(from: directory)
        extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        server = try await TinyHTTPServer(index: "<title>Debugged</title><p>page</p>")
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

    private func call(_ method: String, _ params: [String: Any] = [:]) async -> (result: Any?, error: String?) {
        await router.route(namespace: "debugger", method: method, params: params, extensionId: extensionId, fromWorker: true, registry: registry)
    }

    private func send(_ method: String, _ params: [String: Any] = [:], tabId: Int = 7) async -> (result: [String: Any], error: String?) {
        let reply = await call("sendCommand", ["target": ["tabId": tabId], "method": method, "params": params])
        return (reply.result as? [String: Any] ?? [:], reply.error)
    }

    /// Opens the test page in a new tab, loaded, and returns its id and position.
    private func openTab() async throws -> (id: UUID, position: [String: Int]) {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        try await waitUntil("the page loads") { engine.currentTitle == "Debugged" && !engine.wkWebView.isLoading }
        let adapter = try XCTUnwrap(window.tabManager.tabAdapter(for: tab.id))
        return (tab.id, try XCTUnwrap(registry.tabPosition(of: adapter, extensionId: extensionId)))
    }

    private func attach(_ position: [String: Int], tabId: Int = 7, version: String = "1.3") async -> String? {
        await call("attach", ["target": ["tabId": tabId], "tab": position, "requiredVersion": version]).error
    }

    private func events(_ name: String) -> [[Any]] {
        registry.gapEvents.undelivered(to: extensionId).filter { "\($0.namespace).\($0.event)" == name }.map(\.args)
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        guard await pollUntil(timeout: 10, condition) else { return XCTFail("Timed out waiting until \(what)") }
    }

    func testAttachEvaluateHearAnEventAndDetachWhenTheTabCloses() async throws {
        let tab = try await openTab()
        let attachError = await attach(tab.position)
        XCTAssertNil(attachError)

        let evaluated = await send("Runtime.evaluate", ["expression": "6 * 7", "returnByValue": true])
        XCTAssertNil(evaluated.error)
        XCTAssertEqual((evaluated.result["result"] as? [String: Any])?["value"] as? Int, 42)

        let enabled = await send("Runtime.enable")
        XCTAssertNil(enabled.error)
        XCTAssertTrue(events("debugger.onEvent").contains { $0[1] as? String == "Runtime.executionContextCreated" })
        _ = await send("Runtime.evaluate", ["expression": "console.log('from the page')"])
        try await waitUntil("the console event arrives") {
            events("debugger.onEvent").contains { args in
                let parameters = args[2] as? [String: Any]
                let first = (parameters?["args"] as? [[String: Any]])?.first
                return args[1] as? String == "Runtime.consoleAPICalled" && first?["value"] as? String == "from the page"
            }
        }
        XCTAssertEqual(events("debugger.onEvent").first?[0] as? [String: Int], ["tabId": 7])

        let unknown = await send("Foo.bar")
        XCTAssertEqual(unknown.error, #"{"code":-32601,"message":"'Foo.bar' wasn't found"}"#)

        window.closeTabStateFirst(id: tab.id, undoable: false)
        try await waitUntil("the tab detaches") { !events("debugger.onDetach").isEmpty }
        XCTAssertEqual(events("debugger.onDetach").first?[1] as? String, "target_closed")
        let afterClose = await send("Runtime.evaluate", ["expression": "1"])
        XCTAssertEqual(afterClose.error, "Debugger is not attached to the tab with id: 7.")
    }

    func testAttachFailsAsChromeDoes() async throws {
        let tab = try await openTab()

        let badVersion = await attach(tab.position, version: "2.0")
        XCTAssertEqual(badVersion, "Requested protocol version is not supported: 2.0.")
        let noTab = await call("attach", ["target": ["tabId": 99], "requiredVersion": "1.3"]).error
        XCTAssertEqual(noTab, "No tab with given id 99.")
        let first = await attach(tab.position)
        XCTAssertNil(first)
        let second = await attach(tab.position)
        XCTAssertEqual(second, "Another debugger is already attached to the tab with id: 7.")

        let detached = await call("detach", ["target": ["tabId": 7]])
        XCTAssertNil(detached.error)
        XCTAssertTrue(events("debugger.onDetach").isEmpty, "an extension's own detach fires no onDetach")
        let again = await call("detach", ["target": ["tabId": 7]])
        XCTAssertEqual(again.error, "Debugger is not attached to the tab with id: 7.")
    }

    func testCancelFromTheBannerDetachesTheExtension() async throws {
        let tab = try await openTab()
        _ = await attach(tab.position)

        let message = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "cancelExtensionDebugging", "payload": ["id": "\(registry.profileId.uuidString)/\(extensionId!)"]
        ]))
        _ = await DebuggerBridgeHandler.shared.handle(message: message)

        XCTAssertEqual(events("debugger.onDetach").first?[1] as? String, "canceled_by_user")
        let targets = await call("getTargets").result as? [[String: Any]] ?? []
        XCTAssertEqual(targets.first { $0["id"] as? String == tab.id.uuidString }?["attached"] as? Bool, false)
    }

    func testDomAndScreenshotCommandsTranslate() async throws {
        let tab = try await openTab()
        _ = await attach(tab.position)

        let document = await send("DOM.getDocument")
        let root = try XCTUnwrap(document.result["root"] as? [String: Any], document.error ?? "")
        XCTAssertEqual(root["backendNodeId"] as? Int, root["nodeId"] as? Int)
        let found = await send("DOM.querySelector", ["nodeId": root["nodeId"] ?? 0, "selector": "p"])
        let html = await send("DOM.getOuterHTML", ["nodeId": found.result["nodeId"] ?? 0])
        XCTAssertEqual(html.result["outerHTML"] as? String, "<p>page</p>")
        let box = await send("DOM.getBoxModel", ["nodeId": found.result["nodeId"] ?? 0])
        XCTAssertEqual(((box.result["model"] as? [String: Any])?["content"] as? [Double])?.count, 8, box.error ?? "")

        let shot = await send("Page.captureScreenshot")
        let png = try XCTUnwrap((shot.result["data"] as? String).flatMap { Data(base64Encoded: $0) }, shot.error ?? "")
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testInputClicksAndTypes() async throws {
        let tab = try await openTab()
        _ = await attach(tab.position)
        _ = await send("Runtime.evaluate", ["expression": """
            document.body.innerHTML = '<button style="position:fixed;left:10px;top:10px;width:100px;height:40px" onclick="document.title=\\'clicked\\'">B</button><input id=field style="position:fixed;left:10px;top:80px">'
            """])
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))

        for type in ["mousePressed", "mouseReleased"] {
            let reply = await send("Input.dispatchMouseEvent", ["type": type, "x": 60, "y": 30, "button": "left", "clickCount": 1])
            XCTAssertNil(reply.error)
        }
        try await waitUntil("the click lands") { engine.currentTitle == "clicked" }

        _ = await send("Runtime.evaluate", ["expression": "document.getElementById('field').focus()"])
        _ = await send("Input.dispatchKeyEvent", ["type": "keyDown", "key": "a", "text": "a"])
        _ = await send("Input.dispatchKeyEvent", ["type": "keyUp", "key": "a"])
        _ = await send("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": "b"])
        _ = await send("Input.dispatchKeyEvent", ["type": "char", "key": "b", "text": "b"])
        _ = await send("Input.dispatchKeyEvent", ["type": "keyUp", "key": "b"])
        let value = await send("Runtime.evaluate", ["expression": "document.getElementById('field').value", "returnByValue": true])
        XCTAssertEqual((value.result["result"] as? [String: Any])?["value"] as? String, "ab", "an Input command answers once the page handled it")
    }

    func testRestrictedPagesFollowChrome() throws {
        let context = try XCTUnwrap(registry.context(for: extensionId))
        let restriction = { (url: String) in DebuggerBridgeHandler.restriction(of: URL(string: url), for: context) }
        XCTAssertNil(restriction("https://example.com/"))
        XCTAssertNil(restriction("about:blank"))
        XCTAssertEqual(restriction("https://chromewebstore.google.com/detail/x"), "The extensions gallery cannot be scripted.")
        XCTAssertEqual(restriction("lilo-chrome://ui/index.html"), "Cannot access a chrome:// URL")
        XCTAssertEqual(restriction("chrome-extension://other/page.html"), "Cannot access a chrome-extension:// URL of different extension")
        XCTAssertNil(restriction(context.baseURL.appendingPathComponent("page.html").absoluteString))
        XCTAssertEqual(restriction("file:///tmp/a.html"), "Cannot attach to this target.")
    }
}
