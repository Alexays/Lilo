import XCTest
import WebKit
@testable import Lilo

@MainActor
final class AgentInputTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var field: NSTextField!
    private var engine: WKWebViewTab!
    private var keyReturned = false

    private static let page = """
    <!doctype html><body style="margin:0">
    <input id="i" style="position:absolute;left:20px;top:20px;width:200px;height:30px">
    <button id="b" style="position:absolute;left:20px;top:80px;width:200px;height:60px">B</button>
    <script>
    window.clicks = 0; window.keys = [];
    document.getElementById('b').addEventListener('click', () => clicks++);
    document.addEventListener('keydown', e => keys.push(e.key + ':' + (e.metaKey ? 'M' : '') + (e.shiftKey ? 'S' : '')));
    </script></body>
    """

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        controller = makeTestWindow(context, showing: space.id)
        controller.createTabStateFirst(url: URL(string: "https://example.com"))
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil, activate: false))
        engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        engine.isAgentControlled = true

        // Transparent, off screen and never made key: the test must not show anything to whoever runs it
        // nor take their keyboard. Ordering a titled window in pulls it on screen, so it moves out after.
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrame(NSRect(x: -20000, y: -20000, width: 800, height: 600), display: false)
        let content = try XCTUnwrap(window.contentView)
        engine.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        content.addSubview(engine.view)
        let cover = NSView(frame: engine.view.frame)
        cover.wantsLayer = true
        content.addSubview(cover)
        field = NSTextField(frame: NSRect(x: 0, y: 500, width: 200, height: 24))
        content.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))

        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://agent.test/"))
        // The initial blank document is complete too: wait for this page's own button.
        await pollUntil(timeout: 10) {
            await (try? self.webView.evaluateJavaScript("document.readyState == 'complete' && !!document.getElementById('b')") as? Bool) == true
        }
    }

    override func tearDown() {
        // A real close: leaving the registry, its space and its event monitors lets the window go.
        controller.window?.close()
        controller = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private var webView: WKWebView { engine.view as! WKWebView }

    private func js(_ script: String) async throws -> Any? { try await webView.evaluateJavaScript(script) }

    private var userFocusIntact: Bool {
        ((controller.window?.firstResponder as? NSTextView)?.delegate as AnyObject?) === field
    }

    /// The click reaches the covered page. The press waits in WebKit's mouse queue behind a move while this process, busy as under load,
    /// cannot yet hear that the page handled the move: the page gets the press well after the agent's listener.
    func testAClickHeldBackInWebKitsQueueLandsOnce() async throws {
        let point = CGPoint(x: 120, y: 110)
        AgentInput.move(webView, to: point)
        DispatchQueue.main.async { let end = Date().addingTimeInterval(0.8); while Date() < end {} }

        await AgentInput.click(webView, at: point)

        let clicks = try await js("clicks") as? Int
        XCTAssertEqual(clicks, 1)
    }

    func testAgentTypingFillsTheFocusedInputAndNeverMovesUserFocus() async throws {
        XCTAssertTrue(userFocusIntact)

        await AgentInput.click(webView, at: CGPoint(x: 120, y: 35))
        await AgentInput.type(webView, text: "abc")
        await AgentInput.key(webView, chord: "ArrowLeft")
        try await Task.sleep(for: .milliseconds(300))

        let value = try await js("document.getElementById('i').value") as? String
        XCTAssertEqual(value, "abc")
        XCTAssertTrue(userFocusIntact, "the user's field keeps the keyboard")
    }

    func testDisplayedAgentTabCanTakeFocus() throws {
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.makeFirstResponder(webView), "a hidden agent tab never takes focus")

        controller.displayedTabIds.insert(engine.id)

        XCTAssertTrue(window.makeFirstResponder(webView), "the user looking at the agent tab can type in it")
    }

    /// Keys a field handles silently: WebKit beeps at an edit command with nothing to act on.
    func testKeyChordsReachPage() async throws {
        await AgentInput.click(webView, at: CGPoint(x: 120, y: 35))
        await AgentInput.key(webView, chord: "shift+a ArrowLeft cmd+a")
        await pollUntil { (try? await self.js("keys.length") as? Int) == 3 }

        let keys = try await js("keys") as? [String]
        XCTAssertEqual(keys, ["A:S", "ArrowLeft:", "a:M"])
    }

    /// Cmd+A waits in WebKit's key queue behind an ArrowRight whose keyup the page takes 1.5 s over.
    private static let slowArrowKeyUp = "addEventListener('keyup', e => { if (e.key === 'ArrowRight') { const end = performance.now() + 1500; while (performance.now() < end); } })"

    func testSelectAllLeftToAPageThatHandlesItWhenTheKeyArrivesLate() async throws {
        _ = try await js("i.value = 'hello'; addEventListener('keydown', e => { if (e.metaKey && e.key === 'a') e.preventDefault() }); " + Self.slowArrowKeyUp)
        await AgentInput.click(webView, at: CGPoint(x: 120, y: 35))

        await AgentInput.key(webView, chord: "ArrowRight cmd+a")

        let selected = try await js("i.selectionEnd - i.selectionStart") as? Int
        XCTAssertEqual(selected, 0, "the page's own shortcut wins over the menu's")
    }

    func testSelectAllRunsOnAPageThatLeavesItWhenTheKeyArrivesLate() async throws {
        _ = try await js("i.value = 'hello'; " + Self.slowArrowKeyUp)
        await AgentInput.click(webView, at: CGPoint(x: 120, y: 35))

        await AgentInput.key(webView, chord: "ArrowRight cmd+a")

        let selected = try await js("i.selectionEnd - i.selectionStart") as? Int
        XCTAssertEqual(selected, 5)
    }

    /// Registered before the agent's listener, so the agent never hears the keyup.
    private static let swallowedKeyUp = "addEventListener('keyup', e => e.stopImmediatePropagation(), true)"

    /// Presses cmd+a and reports whether it returned within `seconds`.
    private func selectAllReturns(within seconds: TimeInterval) async -> Bool {
        keyReturned = false
        // Not awaited: a stalled press must fail the test, not hang it.
        Task { await AgentInput.key(webView, chord: "cmd+a"); keyReturned = true }
        return await pollUntil(timeout: seconds) { self.keyReturned }
    }

    func testSelectAllLeftToAPageThatHandlesItAndSwallowsTheKeyUp() async throws {
        _ = try await js("i.value = 'hello'; addEventListener('keydown', e => { if (e.metaKey && e.key === 'a') e.preventDefault() }); " + Self.swallowedKeyUp)
        await AgentInput.click(webView, at: CGPoint(x: 120, y: 35))

        let returned = await selectAllReturns(within: 5)

        XCTAssertTrue(returned, "a swallowed keyup must not hold the call")
        let selected = try await js("i.selectionEnd - i.selectionStart") as? Int
        XCTAssertEqual(selected, 0, "the page's own shortcut wins over the menu's")
    }

    func testSelectAllRunsOnAPageThatLeavesItButSwallowsTheKeyUp() async throws {
        _ = try await js("i.value = 'hello'; " + Self.swallowedKeyUp)
        await AgentInput.click(webView, at: CGPoint(x: 120, y: 35))

        let returned = await selectAllReturns(within: 5)

        XCTAssertTrue(returned, "a swallowed keyup must not hold the call")
        let selected = try await js("i.selectionEnd - i.selectionStart") as? Int
        XCTAssertEqual(selected, 5)
    }

    func testSelectAllRunsInAFocusedFrame() async throws {
        _ = try await js("""
            const frame = document.createElement('iframe')
            frame.srcdoc = '<input id="f" value="hello">'
            frame.style = 'position:absolute;left:300px;top:20px'
            document.body.append(frame)
            """)
        await pollUntil { (try? await self.js("!!document.querySelector('iframe').contentDocument?.getElementById('f')") as? Bool) == true }
        _ = try await js("document.querySelector('iframe').contentDocument.getElementById('f').focus()")

        await AgentInput.key(webView, chord: "cmd+a")

        let selected = try await js("(f => f.selectionEnd - f.selectionStart)(document.querySelector('iframe').contentDocument.getElementById('f'))") as? Int
        XCTAssertEqual(selected, 5)
    }
}
