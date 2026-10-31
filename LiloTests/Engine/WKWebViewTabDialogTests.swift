import AppKit
import WebKit
import XCTest
@testable import Lilo

/// A page's alert, confirm, prompt or sign-in covers its own tab only, and a beforeunload prompt never waits where
/// nobody can see it: a page off screen leaves without one unless the user closes its tab.
@MainActor
final class WKWebViewTabDialogTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var profileId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        controller = MainWindowController(context: context)
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        // Transparent, off screen and never key, so nothing shows to whoever runs the tests.
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 700), display: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        try XCTUnwrap(window.contentView).addSubview(container)
        controller.contentContainerView = container
        context.windows.add(controller)
        controller.switchToSpace(space.id)
        controller.createTabStateFirst(url: nil)
    }

    override func tearDown() {
        if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        controller.window?.close()
        controller = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func load(_ html: String, in engine: WKWebViewTab) async {
        engine.wkWebView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil { !engine.wkWebView.isLoading && engine.wkWebView.url != nil }
    }

    /// A page tab with `html` loaded, shown unless `activate` is false.
    private func pageTab(_ html: String = "<p>page</p>", activate: Bool = true) async throws -> (UUID, WKWebViewTab) {
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil, activate: activate))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        await load(html, in: engine)
        return (tab.id, engine)
    }

    /// Runs `script` on the page once the evaluation returned: a dialog blocks the page until it is answered.
    private func raise(_ script: String, in engine: WKWebViewTab) async throws -> TabModalDialogView {
        _ = try await engine.wkWebView.evaluateJavaScript("setTimeout(() => { \(script) }); true")
        let raised = await pollUntil { !engine.modalDialogs.isEmpty }
        XCTAssertTrue(raised, script)
        return try XCTUnwrap(engine.modalDialogs.first)
    }

    private func pageValue(_ expression: String, in engine: WKWebViewTab) async -> Any? {
        try? await engine.wkWebView.evaluateJavaScript(expression)
    }

    func testTabOfABackgroundSpaceLeavesWithoutABeforeunloadPrompt() async throws {
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        await load("<script>addEventListener('beforeunload', e => e.preventDefault())</script>", in: engine)
        // A script run by the app counts as a user gesture: WebKit asks only a page the user used.
        _ = try await engine.wkWebView.evaluateJavaScript("document.body.click(); true")
        controller.switchToSpace(try browserContext.context.spaceManager.createSpace(name: "Other", profileId: profileId).id)
        XCTAssertNil(engine.view.window)

        _ = try await engine.wkWebView.evaluateJavaScript("setTimeout(() => location.href = 'about:blank'); true")

        let left = await pollUntil { engine.wkWebView.url?.absoluteString == "about:blank" }
        XCTAssertTrue(left, "the page-initiated navigation completes")
    }

    func testAlertOfABackgroundTabWaitsOverItsOwnPage() async throws {
        let window = try XCTUnwrap(controller.window)
        let active = try XCTUnwrap(controller.tabManager.activeEngineTab)
        await load("<p>active</p>", in: active)
        let (tabId, engine) = try await pageTab(activate: false)
        XCTAssertNil(engine.view.window)

        let dialog = try await raise("window.answered = alert('hi') ?? true", in: engine)

        XCTAssertNotNil(controller.tabManager.tab(for: tabId)?.awaitingInputSince, "the sidebar marks the tab as waiting for the user")
        XCTAssertTrue(dialog.superview === engine.wkWebView, "the alert waits over its own page")
        XCTAssertNil(window.attachedSheet, "nothing covers the window")

        // The tab on screen goes on: its own page asks and gets its answer while the other one waits.
        let confirm = try await raise("window.answer = confirm('sure?')", in: active)
        try XCTUnwrap(defaultButton(of: confirm)).performClick(nil)
        let confirmed = await pollUntil { await self.pageValue("window.answer", in: active) as? Bool == true }
        XCTAssertTrue(confirmed, "the shown tab's page runs on")
        XCTAssertEqual(engine.modalDialogs.count, 1, "the background alert still waits")

        controller.activateTabStateFirst(id: tabId)

        let focused = await pollUntil { (window.firstResponder as? NSView)?.isDescendant(of: dialog) == true }
        XCTAssertTrue(focused, "the alert takes the keyboard once its tab shows")
        try XCTUnwrap(defaultButton(of: dialog)).performClick(nil)
        let answered = await pollUntil { await self.pageValue("window.answered === true", in: engine) as? Bool == true }
        XCTAssertTrue(answered, "the page runs on once the alert is answered")
        XCTAssertNil(dialog.superview)
        XCTAssertNil(controller.tabManager.tab(for: tabId)?.awaitingInputSince)
    }

    func testSwitchingTabsKeepsTheDialogAndWhatWasTyped() async throws {
        let window = try XCTUnwrap(controller.window)
        let (tabId, engine) = try await pageTab()

        let dialog = try await raise("window.answer = prompt('Name?', 'default')", in: engine)
        let field = try XCTUnwrap(textFields(in: dialog).first)
        let typing = await pollUntil { ((window.firstResponder as? NSText)?.delegate as? NSView) === field }
        XCTAssertTrue(typing, "the prompt's field takes the keyboard")
        (window.firstResponder as? NSTextView)?.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))

        controller.createTabStateFirst(url: nil)
        XCTAssertNil(engine.view.window)
        XCTAssertNotNil(controller.tabManager.tab(for: tabId)?.awaitingInputSince, "the tab it left is marked as waiting")
        controller.activateTabStateFirst(id: tabId)

        XCTAssertTrue(engine.modalDialogs.first === dialog)
        XCTAssertEqual(field.stringValue, "typed", "what was typed is still there")
        let refocused = await pollUntil { ((window.firstResponder as? NSText)?.delegate as? NSView) === field }
        XCTAssertTrue(refocused, "the field has the keyboard again")
        try XCTUnwrap(defaultButton(of: dialog)).performClick(nil)
        let answered = await pollUntil { await self.pageValue("window.answer", in: engine) as? String == "typed" }
        XCTAssertTrue(answered, "the page gets what was typed")
    }

    func testClosingTheTabAnswersItsDialog() async throws {
        let (tabId, engine) = try await pageTab()
        let dialog = try await raise("confirm('sure?')", in: engine)

        controller.closeTabStateFirst(id: tabId)

        let closed = await pollUntil { self.controller.tabManager.tab(for: tabId) == nil }
        XCTAssertTrue(closed, "the page blocked on its dialog does not hold the close")
        XCTAssertNil(dialog.superview, "the dialog is answered")
        XCTAssertTrue(engine.modalDialogs.isEmpty)
    }

    func testNavigatingAwayAnswersTheDialog() async throws {
        let (tabId, engine) = try await pageTab()
        _ = try await raise("alert('hi')", in: engine)

        engine.loadURL(try XCTUnwrap(URL(string: "about:blank")))

        let left = await pollUntil { engine.wkWebView.url?.absoluteString == "about:blank" && !engine.wkWebView.isLoading }
        XCTAssertTrue(left, "the new page loads")
        XCTAssertTrue(engine.modalDialogs.isEmpty)
        XCTAssertNil(controller.tabManager.tab(for: tabId)?.awaitingInputSince)
    }

    func testKeysAnswerTheDialogOnlyWhileItHasTheKeyboard() async throws {
        let window = try XCTUnwrap(controller.window)
        let (_, engine) = try await pageTab()
        let dialog = try await raise("window.answer = confirm('sure?')", in: engine)

        window.makeFirstResponder(controller.chromeWebView)
        _ = window.performKeyEquivalent(with: try key(53, in: window))
        XCTAssertNotNil(dialog.superview, "Escape typed in the sidebar or address bar leaves the dialog alone")

        window.makeFirstResponder(engine.wkWebView)
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: dialog) == true, "focusing the page focuses its dialog")
        XCTAssertTrue(window.performKeyEquivalent(with: try key(36, in: window)))
        let accepted = await pollUntil { await self.pageValue("window.answer", in: engine) as? Bool == true }
        XCTAssertTrue(accepted, "Return answers as the default button")
        XCTAssertTrue(window.firstResponder === engine.wkWebView, "the page has the keyboard back")

        let again = try await raise("window.answer = confirm('again?')", in: engine)
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: again) == true)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(53, in: window)))
        let cancelled = await pollUntil { await self.pageValue("window.answer", in: engine) as? Bool == false }
        XCTAssertTrue(cancelled, "Escape answers as Cancel")
    }

    func testReturnAnywhereElseInTheWindowLeavesTheDialogAlone() async throws {
        let window = try XCTUnwrap(controller.window)
        let (_, engine) = try await pageTab()
        let dialog = try await raise("window.answer = confirm('sure?')", in: engine)
        XCTAssertNil(window.defaultButtonCell, "the dialog's default button is not the window's")

        window.makeFirstResponder(nil)
        window.sendEvent(try key(36, in: window))
        _ = window.performKeyEquivalent(with: try key(36, in: window))

        XCTAssertNotNil(dialog.superview, "a Return nothing handles does not answer the dialog")
        XCTAssertEqual(engine.modalDialogs.count, 1)
    }

    func testCommittingANewPageAnswersTheDialogOfTheOldOne() async throws {
        let server = try await TinyHTTPServer { request in
            request.hasPrefix("GET /secret")
                ? ("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"test\"", "Content-Type: text/plain"], Data("denied".utf8))
                : ("200 OK", ["Content-Type: text/html"], Data("<p>page</p>".utf8))
        }
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        _ = await pollUntil { !engine.wkWebView.isLoading && engine.wkWebView.url != nil }
        _ = try await raise("fetch('/secret')", in: engine)

        _ = try await engine.wkWebView.evaluateJavaScript("location.href = 'about:blank'; true")

        let left = await pollUntil { engine.wkWebView.url?.absoluteString == "about:blank" && engine.modalDialogs.isEmpty }
        XCTAssertTrue(left, "the old page's sign-in goes with it")
        XCTAssertNil(controller.tabManager.tab(for: tab.id)?.awaitingInputSince)
    }

    func testAnEndedPageProcessAnswersTheDialog() async throws {
        let (_, engine) = try await pageTab()
        _ = try await raise("alert('hi')", in: engine)

        engine.wkWebView.perform(NSSelectorFromString("_killWebContentProcessAndResetState"))

        let answered = await pollUntil { engine.modalDialogs.isEmpty }
        XCTAssertTrue(answered, "the dialog of a page that is gone does not stay over its tab")
    }

    func testStoppingALoadAnswersItsSignIn() async throws {
        let server = try await TinyHTTPServer { _ in
            ("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"test\"", "Content-Type: text/html"], Data("<p>denied</p>".utf8))
        }
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        let asked = await pollUntil { !engine.modalDialogs.isEmpty }
        XCTAssertTrue(asked)

        engine.stopLoading()

        XCTAssertTrue(engine.modalDialogs.isEmpty)
        XCTAssertNil(controller.tabManager.tab(for: tab.id)?.awaitingInputSince)
    }

    func testABurstOfSignInsToOneSiteAsksOnce() async throws {
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET / ") { return ("200 OK", ["Content-Type: text/html"], Data("<p>page</p>".utf8)) }
            return request.contains("Authorization: Basic dXNlcjpzZWNyZXQ=")
                ? ("200 OK", ["Content-Type: text/plain"], Data("ok".utf8))
                : ("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"test\"", "Content-Type: text/plain"], Data("denied".utf8))
        }
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        _ = await pollUntil { !engine.wkWebView.isLoading && engine.wkWebView.url != nil }

        let dialog = try await raise(
            "Promise.all(['/a', '/b'].map(u => fetch(u).then(r => r.status))).then(s => window.statuses = s.join())", in: engine
        )
        XCTAssertEqual(engine.modalDialogs.count, 1)

        let fields = textFields(in: dialog)
        fields.first?.stringValue = "user"
        fields.last?.stringValue = "secret"
        try XCTUnwrap(defaultButton(of: dialog)).performClick(nil)

        let signedIn = await pollUntil { await self.pageValue("window.statuses", in: engine) as? String == "200,200" }
        XCTAssertTrue(signedIn, "both requests get the credentials typed once")
        XCTAssertTrue(engine.modalDialogs.isEmpty, "WebKit holds the second challenge until the first is answered, then reuses its credential")
    }

    func testVoiceOverReadsTheDialogInPlaceOfThePage() async throws {
        let (_, engine) = try await pageTab()
        let dialog = try await raise("alert('hi')", in: engine)

        let children = NSAccessibility.unignoredChildren(from: engine.wkWebView.accessibilityChildren() ?? [])
        XCTAssertEqual(children.count, 1, "the page under the dialog is out of reach")
        XCTAssertTrue(children.first as? TabModalDialogView === dialog)
        // WebKit answers VoiceOver through the older attribute entry point.
        let legacy = engine.wkWebView.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: NSAccessibility.Attribute.children.rawValue)
        let legacyChildren = legacy?.takeUnretainedValue() as? [Any]
        XCTAssertEqual(legacyChildren?.count, 1)
        XCTAssertTrue(legacyChildren?.first as? TabModalDialogView === dialog, "\(String(describing: legacyChildren))")
        XCTAssertEqual(dialog.accessibilitySubrole(), .dialog)
        XCTAssertEqual(dialog.accessibilityLabel(), "example.com says")
    }

    func testClosingABackgroundTabShowsItAndAsksBeforeLeaving() async throws {
        let window = try XCTUnwrap(controller.window)
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        await load("<script>addEventListener('beforeunload', e => e.preventDefault())</script>", in: engine)
        _ = try await engine.wkWebView.evaluateJavaScript("document.body.click(); true")
        controller.createTabStateFirst(url: nil)
        XCTAssertNil(engine.view.window)

        controller.closeTabStateFirst(id: tab.id)

        let asked = await pollUntil { window.attachedSheet != nil }
        XCTAssertTrue(asked, "the page gets to ask before its tab closes")
        XCTAssertEqual(controller.tabManager.activeOpenTabId, tab.id, "the tab shows with its question")
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let closed = await pollUntil { self.controller.tabManager.tab(for: tab.id) == nil }
        XCTAssertTrue(closed, "the tab closes once the user leaves")
    }

    func testAuthPromptOfABackgroundTabWaitsOverItsPageAndSignsIn() async throws {
        let window = try XCTUnwrap(controller.window)
        let server = try await TinyHTTPServer { request in
            request.contains("Authorization: Basic dXNlcjpzZWNyZXQ=")
                ? ("200 OK", ["Content-Type: text/html"], Data("<p>welcome</p>".utf8))
                : ("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"test\"", "Content-Type: text/html"], Data("<p>denied</p>".utf8))
        }
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/"), activate: false))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))

        let marked = await pollUntil { self.controller.tabManager.tab(for: tab.id)?.awaitingInputSince != nil }
        XCTAssertTrue(marked, "the sidebar marks the tab as waiting for the user")
        XCTAssertNil(window.attachedSheet, "nothing covers the window")
        let dialog = try XCTUnwrap(engine.modalDialogs.first)
        XCTAssertTrue(texts(in: dialog).contains("Authentication Required"), "\(texts(in: dialog))")

        controller.activateTabStateFirst(id: tab.id)

        let fields = textFields(in: dialog)
        XCTAssertEqual(fields.count, 2)
        let password = try XCTUnwrap(fields.last as? NSSecureTextField, "the password is typed in secure entry")
        let typing = await pollUntil { ((window.firstResponder as? NSText)?.delegate as? NSView) === fields.first }
        XCTAssertTrue(typing, "the username field takes the keyboard once the tab shows")
        XCTAssertTrue(buttons(in: dialog).contains { $0.title == "Remember this password" }, "a profile can keep the password")
        fields.first?.stringValue = "user"
        password.stringValue = "secret"
        try XCTUnwrap(defaultButton(of: dialog)).performClick(nil)

        let signedIn = await pollUntil { await self.pageValue("document.body?.innerText ?? ''", in: engine) as? String == "welcome" }
        XCTAssertTrue(signedIn, "the server gets the credentials")
    }

    func testCancellingTheAuthPromptShowsTheServersPage() async throws {
        let server = try await TinyHTTPServer { _ in
            ("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"test\"", "Content-Type: text/html"], Data("<p>denied</p>".utf8))
        }
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        let asked = await pollUntil { !engine.modalDialogs.isEmpty }
        XCTAssertTrue(asked)
        let dialog = try XCTUnwrap(engine.modalDialogs.first)

        try XCTUnwrap(buttons(in: dialog).first { $0.title == "Cancel" }).performClick(nil)

        let shown = await pollUntil { await self.pageValue("document.body?.innerText ?? ''", in: engine) as? String == "denied" }
        XCTAssertTrue(shown, "the server's own 401 page shows")
    }

    func testAlertSaysWhichSiteIsAsking() async throws {
        let (_, engine) = try await pageTab("<iframe src=\"data:text/html,<script>onmessage = () => alert('framed')</script>\"></iframe>")

        let page = try await raise("alert('hi')", in: engine)
        XCTAssertTrue(texts(in: page).contains("example.com says"), "\(texts(in: page))")
        XCTAssertTrue(texts(in: page).contains("hi"), "\(texts(in: page))")
        try XCTUnwrap(defaultButton(of: page)).performClick(nil)
        XCTAssertTrue(engine.modalDialogs.isEmpty)

        let frame = try await raise("frames[0].postMessage(1, '*')", in: engine)
        XCTAssertTrue(texts(in: frame).contains("An embedded page on example.com says"), "\(texts(in: frame))")
    }

    func testRepeatedDialogsCanBeStopped() async throws {
        let (_, engine) = try await pageTab()

        let first = try await raise("window.count = 0; while (window.count < 1000) { window.count++; alert(window.count) }", in: engine)
        XCTAssertNil(suppressionBox(in: first), "the first dialog offers nothing more")
        try XCTUnwrap(defaultButton(of: first)).performClick(nil)

        let offered = await pollUntil { engine.modalDialogs.first.flatMap(self.suppressionBox(in:)) != nil }
        XCTAssertTrue(offered, "the next one offers to stop them")
        let second = try XCTUnwrap(engine.modalDialogs.first)
        try XCTUnwrap(suppressionBox(in: second)).state = .on
        try XCTUnwrap(defaultButton(of: second)).performClick(nil)

        let freed = await pollUntil { await self.pageValue("window.count", in: engine) as? Int == 1000 }
        XCTAssertTrue(freed, "the page's further dialogs are dismissed")
        XCTAssertTrue(engine.modalDialogs.isEmpty)
    }

    /// Every view under `root`, depth first.
    private func views(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + views(in: $0) }
    }

    private func texts(in dialog: NSView) -> [String] {
        views(in: dialog).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }
    }

    private func textFields(in dialog: NSView) -> [NSTextField] {
        views(in: dialog).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    }

    private func buttons(in dialog: NSView) -> [NSButton] {
        views(in: dialog).compactMap { $0 as? NSButton }
    }

    private func defaultButton(of dialog: NSView) -> NSButton? {
        buttons(in: dialog).first { $0.tintProminence == .primary }
    }

    private func suppressionBox(in dialog: NSView) -> NSButton? {
        buttons(in: dialog).first { $0.title.hasPrefix("Prevent this page") }
    }

    private func key(_ keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        let characters = keyCode == 53 ? "\u{1b}" : "\r"
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }
}
