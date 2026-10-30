import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeGlobalEventRoutingTests: XCTestCase {
    /// A window showing a tab whose web view holds two committed pages, the second current.
    private func makeTabWithHistory(_ browserContext: TemporaryBrowserContext) async throws -> (MainWindowController, WKWebViewTab, first: URL, second: URL) {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: context.profileManager.createProfile(name: "P").id)
        let controller = makeTestWindow(context, showing: space.id)
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        let first = try XCTUnwrap(URL(string: "data:text/html,<p>first</p>"))
        let second = try XCTUnwrap(URL(string: "data:text/html,<input id=i autofocus>"))
        // Each load must commit, not just start, before the next one: only then is it a back-forward entry.
        for url in [first, second] {
            engine.loadURL(url)
            let committed = await pollUntil { engine.wkWebView.backForwardList.currentItem?.url == url }
            XCTAssertTrue(committed, "\(url) never committed")
        }
        return (controller, engine, first, second)
    }

    /// A real release of a mouse's back then forward button, through the window's own monitor.
    func testAMouseBackAndForwardButtonGoThroughTheActiveTabsHistory() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (controller, engine, first, second) = try await makeTabWithHistory(browserContext)
        let webView = engine.wkWebView
        controller.chromeInput.startMonitoring()
        defer { controller.chromeInput.stop() }
        // NSEvent's factory sets no button number; one built from a bare CGEvent loses its window.
        func release(_ button: Int64) throws {
            let cgEvent = try XCTUnwrap(NSEvent.mouseEvent(
                with: .otherMouseUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
            )?.cgEvent)
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: button)
            NSApp.sendEvent(try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        }

        try release(3)
        let wentBack = await pollUntil { webView.backForwardList.currentItem?.url == first }
        XCTAssertTrue(wentBack, "at \(webView.backForwardList.currentItem?.url.absoluteString ?? "nil"), loading \(webView.isLoading)")
        try release(4)
        let wentForward = await pollUntil { webView.backForwardList.currentItem?.url == second }
        XCTAssertTrue(wentForward, "at \(webView.backForwardList.currentItem?.url.absoluteString ?? "nil"), loading \(webView.isLoading)")
    }

    func testThePreviousPageOpensInABackgroundTab() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (controller, engine, first, second) = try await makeTabWithHistory(browserContext)
        let tabs = controller.tabManager.openTabs.count

        controller.openHistoryInNewTab(forward: false, inBackground: true)

        XCTAssertEqual(controller.tabManager.openTabs.count, tabs + 1)
        XCTAssertEqual(controller.tabManager.activeTabId, engine.id)
        XCTAssertTrue(controller.tabManager.openTabs.contains { $0.id != engine.id && $0.url == first })
        XCTAssertEqual(engine.wkWebView.backForwardList.currentItem?.url, second, "the tab itself stays where it is")
    }

    /// ⌘← goes back only while the page has no caret to move: in a focused field it moves the caret.
    func testCommandLeftGoesBackOnlyWhenThePageDoesNotUseIt() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (controller, engine, first, second) = try await makeTabWithHistory(browserContext)
        let webView = engine.wkWebView
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrame(NSRect(x: -20000, y: -20000, width: 800, height: 600), display: false)
        engine.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView?.addSubview(engine.view)
        XCTAssertTrue(window.makeFirstResponder(webView))
        controller.chromeInput.startMonitoring()
        defer { controller.chromeInput.stop() }
        func commandLeft() throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                isARepeat: false, keyCode: 123
            )))
        }

        let attributes = { WebViewPrivateAccessors(webView).int("_selectionAttributes") }
        _ = try await webView.evaluateJavaScript("i.focus(); true")
        await pollUntil { attributes() != 0 }
        try commandLeft()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(webView.backForwardList.currentItem?.url, second, "the field takes ⌘←")

        _ = try await webView.evaluateJavaScript("i.blur(); true")
        await pollUntil { attributes() == 0 }
        try commandLeft()
        let wentBack = await pollUntil { webView.backForwardList.currentItem?.url == first }
        XCTAssertTrue(wentBack)
    }

    /// A shown window whose focused page is `engine`'s, with the window's key monitor running.
    private func focusPage(of engine: WKWebViewTab, in controller: MainWindowController) throws -> NSWindow {
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrame(NSRect(x: -20000, y: -20000, width: 800, height: 600), display: false)
        engine.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView?.addSubview(engine.view)
        XCTAssertTrue(window.makeFirstResponder(engine.wkWebView))
        // AppKit hands key equivalents, and WebKit's resend of a key the page let go, to the key window.
        window.makeKey()
        controller.chromeInput.startMonitoring()
        return window
    }

    private func sendKey(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, to window: NSWindow) throws {
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )))
    }

    /// ⌘[ reaches the page first, as in Chrome, through a real WebKit round trip: an editor indenting with it
    /// keeps the tab where it is, and a page that lets it go still goes back.
    func testThePageGetsCommandBracketBeforeHistory() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (controller, engine, first, second) = try await makeTabWithHistory(browserContext)
        let webView = engine.wkWebView
        let window = try focusPage(of: engine, in: controller)
        defer { controller.chromeInput.stop() }
        _ = try await webView.evaluateJavaScript(
            "onkeydown = e => { if (e.metaKey && e.key == '[') { e.preventDefault(); document.title = 'indented' } }; true"
        )

        try sendKey("[", .command, keyCode: 33, to: window)
        let indented = await pollUntil { webView.title == "indented" }
        XCTAssertTrue(indented, "the page never saw ⌘[")
        XCTAssertEqual(webView.backForwardList.currentItem?.url, second)

        _ = try await webView.evaluateJavaScript("onkeydown = null; true")
        try sendKey("[", .command, keyCode: 33, to: window)
        let wentBack = await pollUntil { webView.backForwardList.currentItem?.url == first }
        XCTAssertTrue(wentBack, "a key the page lets go still goes back")
    }

    func testCmdLRemainsReservedToLilo() {
        let controller = MainWindowController()
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        )!

        XCTAssertTrue(controller.handleKeyboardShortcut(event))
    }

    func testReservedShortcutStaysWithLilo() {
        let controller = MainWindowController()
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        )!

        XCTAssertTrue(controller.handleKeyboardShortcut(event))
    }

    func testNonReservedKeyFallsThroughToActiveContent() {
        let controller = MainWindowController()
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeInput.router.updateContentView(sink)

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )!

        _ = controller.routeUnhandledGlobalEvent(event)

        XCTAssertEqual(sink.calls, [.keyDown("x")])
    }

    func testNonReservedKeyStaysLocalWhenChromeHasFocus() {
        let controller = MainWindowController()
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeInput.router.updateContentView(sink)
        controller.chromeWebView.frame = controller.window!.contentView!.bounds
        controller.window?.contentView?.addSubview(controller.chromeWebView)
        XCTAssertTrue(controller.window!.makeFirstResponder(controller.chromeWebView))
        XCTAssertTrue(controller.isFirstResponderInsideChromeUI())

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )!

        XCTAssertFalse(controller.routeUnhandledGlobalEvent(event))
        XCTAssertEqual(sink.calls, [])
    }

    func testEscapeUsesNativeDeliveryWhenContentHasFocus() {
        let controller = MainWindowController()
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeInput.router.updateContentView(sink)
        controller.window?.contentView?.addSubview(sink)
        XCTAssertTrue(controller.window!.makeFirstResponder(sink))

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!

        XCTAssertFalse(controller.handleKeyboardShortcut(event))
        XCTAssertFalse(controller.routeUnhandledGlobalEvent(event))
        XCTAssertEqual(sink.calls, [])
    }

    func testKeyStaysWithFocusedNonContentViewLikeExtensionPopup() {
        let controller = MainWindowController()
        let contentSink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        controller.chromeInput.router.updateContentView(contentSink)

        // An extension action popup hosted in this window's responder chain needs native delivery: the global fallback
        // would re-dispatch to the active tab and double-type every character.
        let popup = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.window?.contentView?.addSubview(popup)
        XCTAssertTrue(controller.window!.makeFirstResponder(popup))
        XCTAssertFalse(controller.isFirstResponderInsideChromeUI())
        XCTAssertFalse(controller.isFirstResponderInsideContentView())

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        XCTAssertFalse(controller.routeUnhandledGlobalEvent(event))
        XCTAssertEqual(contentSink.calls, [])
    }

    func testOpenHistoryMenuActionFocusesChromeBeforeOpeningCommandBar() {
        let controller = MainWindowController()
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeWebView.frame = controller.window!.contentView!.bounds
        controller.window?.contentView?.addSubview(controller.chromeWebView)
        controller.window?.contentView?.addSubview(sink)
        XCTAssertTrue(controller.window!.makeFirstResponder(sink))
        XCTAssertFalse(controller.isFirstResponderInsideChromeUI())

        controller.openHistory(nil)

        XCTAssertTrue(controller.isFirstResponderInsideChromeUI())
    }
}

@MainActor
private final class TestGlobalKeySinkView: NSView {
    enum Call: Equatable {
        case keyDown(String)
    }

    var calls: [Call] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        calls.append(.keyDown(event.charactersIgnoringModifiers ?? ""))
    }
}
