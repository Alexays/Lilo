import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Bitwarden from the store against a local Vaultwarden. `make ext-e2e-passwords` starts the server, writes the
/// fixture (LILO_E2E_FIXTURE) and runs each test in its own process on one data folder; without it, they skip.
@MainActor
final class PasswordManagerE2ETests: XCTestCase {
    private struct Fixture: Decodable {
        struct Item: Decodable {
            let name: String, username: String, password: String
        }
        let server: String, email: String, password: String
        let item: Item
        /// What the relaunch's prelude logs from the worker.
        let preludeMark: String?
    }

    private static let bitwarden = "nngceckbapebfimnlniiiahkandclblb"
    private static let profileName = "Bitwarden E2E"

    private var context: BrowserContext!
    private var fixture: Fixture!

    override func setUp() async throws {
        try await super.setUp()
        guard let path = ProcessInfo.processInfo.environment["LILO_E2E_FIXTURE"] else {
            throw XCTSkip("make ext-e2e-passwords runs it, with a Vaultwarden server and its fixture")
        }
        // Each step builds on the one before: the first that fails says what broke.
        continueAfterFailure = false
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // LILO_APP_SUPPORT_DIR: the folder both processes share.
        context = BrowserContext(appSupportDirectory: BuildIdentity.appSupportDirectory)
        try await context.bootstrap()
    }

    override func tearDown() {
        // As TemporaryBrowserContext ends one, the folder kept for the next process.
        for window in context?.windows.windows ?? [] { window.window?.close() }
        for tabId in context?.browserState.allTabIds() ?? [] { context.browserState.liveEngine(forTab: tabId)?.teardown() }
        for profile in context?.profileContexts.allContexts ?? [] { profile.extensions.teardown() }
        context?.engineFactory.dropWarmPool()
        context = nil
        super.tearDown()
    }

    /// The login form and the page it posts to, on any port: the vault item matches 127.0.0.1 by base domain.
    private static let pages = """
    <!doctype html><title>Sign in</title>
    <form action="/welcome" method="post">
      <input id="username" name="username" autocomplete="username">
      <input id="password" name="password" type="password" autocomplete="current-password">
      <button id="submit" type="submit">Sign in</button>
    </form>
    """

    private func startSite() async throws -> TinyHTTPServer {
        let login = Data(Self.pages.utf8), welcome = Data("<!doctype html><title>Welcome</title><p>Signed in</p>".utf8)
        return try await TinyHTTPServer { request in
            request.hasPrefix("POST /welcome") ? ("200 OK", ["Content-Type: text/html"], welcome) : ("200 OK", ["Content-Type: text/html"], login)
        }
    }

    /// A window of the e2e profile, on screen as a popover needs, and its registry: made by the first process, found by the second.
    private func makeWindow() throws -> (MainWindowController, ProfileExtensionRegistry) {
        let profiles = try XCTUnwrap(context.profileManager)
        let profileId = try profiles.profiles.first { $0.name == Self.profileName }?.id ?? profiles.createProfile(name: Self.profileName).id
        let spaces = try XCTUnwrap(context.spaceManager)
        let space = try spaces.spaces(for: profileId).first ?? spaces.createSpace(name: "S", profileId: profileId)
        let window = makeTestWindow(context, showing: space.id, size: NSSize(width: 1000, height: 800))
        window.setupExtensions()
        window.window?.orderFront(nil)
        return (window, try context.profileContexts.context(for: profileId).extensions)
    }

    /// Opens `url` in an active tab, attached and unattended as the agent's tabs are, once loaded.
    private func openPage(_ window: MainWindowController, _ url: URL) async throws -> WKWebView {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: url))
        window.activateTabStateFirst(id: tab.id)
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        context.agentControl.attach(engine, to: nil)
        engine.agentDialogHandler = { _ in true }
        let page = try XCTUnwrap(engine.view as? WKWebView)
        _ = await pollUntil(timeout: 10) { !page.isLoading && page.url != nil }
        return page
    }

    /// Bitwarden's popover on the active tab, as its toolbar button opens it.
    private func openPopup(_ window: MainWindowController, _ registry: ProfileExtensionRegistry) async throws -> WKWebView {
        let button = NSMenuItem()
        button.representedObject = Self.bitwarden
        window.openExtensionFromMenu(button)
        var popup: WKWebView?
        _ = await pollUntil(timeout: 20) {
            popup = window.tabManager.activeOpenTabId.flatMap { window.tabManager.tabAdapter(for: $0) }
                .flatMap { registry.context(for: Self.bitwarden)?.action(for: $0)?.popupWebView }
            guard let page = popup else { return false }
            return await self.run("return document.readyState === 'complete' && typeof chrome?.runtime?.id === 'string'", in: page) as? Bool == true
        }
        return try XCTUnwrap(popup, "Bitwarden's popup opens")
    }

    /// Finds, clicks and fills by selector or by a button's text, as a user would; Angular hears the input events.
    private static let helpers = """
    const $ = (selector) => [...document.querySelectorAll(selector)].find((element) => element.getClientRects().length > 0);
    const button = (text) => [...document.querySelectorAll('button, a')].find((element) =>
      element.textContent.trim().toLowerCase() === text.toLowerCase() && element.getClientRects().length > 0 && !element.disabled);
    const fill = (element, value) => {
      element.focus();
      element.value = value;
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
    };
    """

    /// `script`'s value in `page` with the helpers in scope, or nil.
    private func run(_ script: String, in page: WKWebView) async -> Any? {
        try? await page.evaluateJavaScript("(() => { \(Self.helpers) \(script) })()")
    }

    /// Polls `script` until it returns true, for at most `timeout`.
    private func holds(_ script: String, in page: WKWebView, timeout: TimeInterval = 20) async -> Bool {
        await pollUntil(timeout: timeout) { await self.run(script, in: page) as? Bool == true }
    }

    /// Fails with what the popup shows and what the worker logged unless `condition` holds.
    private func expect(_ condition: Bool, _ what: String, _ popup: WKWebView?, _ registry: ProfileExtensionRegistry) async {
        if !condition { XCTFail("\(what): \(await diagnosis(popup, registry))") }
    }

    private func diagnosis(_ popup: WKWebView?, _ registry: ProfileExtensionRegistry) async -> String {
        var text = "no popup"
        if let popup { text = await run("return document.body?.innerText.slice(0, 300)", in: popup) as? String ?? "unread" }
        let consoles = (registry.backgroundDiagnosticsSnapshots().first { $0["id"] as? String == Self.bitwarden }?["pageDiagnostics"] as? [[String: Any]] ?? [])
            .map { "\($0["source"] ?? "?"): \(String(describing: $0["message"] ?? "").prefix(200))" }
        // The last distinct ones: a popup can log the same error many times over.
        var seen: Set<String> = []
        let distinct = consoles.reversed().filter { seen.insert($0).inserted }.prefix(8).reversed()
        let errors = (registry.context(for: Self.bitwarden)?.errors ?? []).suffix(4).map { String($0.localizedDescription.prefix(200)) }
        let worker = registry.lifecycle.worker(of: Self.bitwarden).map { "\($0)" } ?? "none"
        return "popup: \(text.replacingOccurrences(of: "\n", with: " | ")), worker \(worker), consoles \(Array(distinct)), errors \(errors)"
    }

    /// The vault's item for the login page, shown once Bitwarden is signed in and unlocked.
    private var itemShown: String { "document.body.innerText.includes(\(literal(fixture.item.name)))" }

    private func literal(_ string: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed), encoding: .utf8)!
    }

    func testBitwardenSignsInFillsAndOffersToSave() async throws {
        let (window, registry) = try makeWindow()
        let package = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: Self.bitwarden)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try await registry.load(from: package)
        _ = await registry.backgrounds.load(Self.bitwarden)
        let started = await pollUntil(timeout: 20) { registry.lifecycle.worker(of: Self.bitwarden) == .running }
        XCTAssertTrue(started, "Bitwarden's worker starts")
        // Its welcome page would take the toolbar button's click: once no tab opened for 1.5 s, they close.
        var quiet = 0, count = window.tabManager.openTabs.count
        for _ in 0..<12 where quiet < 3 {
            try await Task.sleep(for: .milliseconds(500))
            quiet = window.tabManager.openTabs.count == count ? quiet + 1 : 0
            count = window.tabManager.openTabs.count
        }
        for tab in window.tabManager.openTabs { window.closeTabStateFirst(id: tab.id, undoable: false) }

        let site = try await startSite()
        let page = try await openPage(window, try XCTUnwrap(URL(string: "http://127.0.0.1:\(site.port)/login")))
        let popup = try await openPopup(window, registry)

        // Signs in: past its offer to become the default password manager and its intro, then on the self-hosted server.
        let atLogin = await holds("button('Skip')?.click(); if (!$('#email')) button('Log in')?.click(); return !!$('#email');", in: popup)
        await expect(atLogin, "the popup shows its login page", popup, registry)
        _ = await run("$('[bittypography=body2] button').click();", in: popup)
        let menu = await holds("return !!button('self-hosted');", in: popup, timeout: 5)
        await expect(menu, "the popup's server menu offers a self-hosted server", popup, registry)
        _ = await run("button('self-hosted').click();", in: popup)
        let dialog = await holds("return !!$('#self_hosted_env_settings_form_input_base_url');", in: popup, timeout: 5)
        await expect(dialog, "the popup asks for the self-hosted server's URL", popup, registry)
        _ = await run("""
        fill($('#self_hosted_env_settings_form_input_base_url'), \(literal(fixture.server)));
        $('form[bit-dialog] button[type=submit]').click();
        """, in: popup)
        let onServer = await holds("return !$('#self_hosted_env_settings_form_input_base_url') && /accessing:\\s*self-hosted/i.test(document.body.innerText);", in: popup, timeout: 10)
        await expect(onServer, "the popup accesses the self-hosted server", popup, registry)
        _ = await run("fill($('#email'), \(literal(fixture.email))); $('[data-testid=login-continue-button]').click();", in: popup)
        let askedPassword = await holds("return !!$('#masterPassword');", in: popup)
        await expect(askedPassword, "the popup asks for the master password", popup, registry)
        _ = await run("fill($('#masterPassword'), \(literal(fixture.password))); $('[data-testid=login-submit-button]').click();", in: popup)
        let signedIn = await holds("return \(itemShown)", in: popup, timeout: 60)
        await expect(signedIn, "the popup signs in and suggests the vault's login for the page", popup, registry)

        // Fills the page from the popup's suggestion.
        _ = await run("""
        const item = [...document.querySelectorAll('bit-item')].find((element) => element.innerText.includes(\(literal(fixture.item.name))));
        [...item.querySelectorAll('button')].find((element) => element.textContent.trim() === 'Fill').click();
        """, in: popup)
        let filled = await holds("""
        return document.getElementById('username').value === \(literal(fixture.item.username))
          && document.getElementById('password').value === \(literal(fixture.item.password));
        """, in: page)
        await expect(filled, "the popup fills the login page", popup, registry)

        // A login the vault does not have, submitted, is offered to be saved on the page it leads to.
        // On the page loaded again, as Bitwarden watches the forms of pages that load while it is signed in. Typed and
        // clicked as a user does: it ignores events a script dispatches.
        page.reload()
        _ = await pollUntil(timeout: 10) { !page.isLoading }
        try await Task.sleep(for: .seconds(1))
        for (id, text) in [("username", "new-user@example.com"), ("password", "A new password 42"), ("submit", "")] {
            let box = await run("""
            const box = document.getElementById(\(literal(id))).getBoundingClientRect();
            return [box.x + box.width / 2, box.y + box.height / 2];
            """, in: page) as? [Double]
            let center = try XCTUnwrap(box)
            await AgentInput.click(page, at: CGPoint(x: center[0], y: center[1]))
            await AgentInput.type(page, text: text)
        }
        let offered = await holds("return location.pathname === '/welcome' && !!document.querySelector('bit-notification-bar-root');", in: page)
        // Lets Bitwarden's storage writes land before the process ends: the relaunch reads them.
        try await Task.sleep(for: .seconds(2))
        // Not strict: Bitwarden's 1.5 s fallback sometimes shows the bar before the page has loaded.
        let gap = XCTExpectedFailure.Options()
        gap.isStrict = false
        XCTExpectFailure("""
        Bitwarden waits for the next page's webNavigation.onCompleted with a listener it adds on submission, and WebKit \
        fires that event to no listener of a worker that did not listen to it at startup.
        """, options: gap) {
            XCTAssertTrue(offered, "Bitwarden offers to save the new login on the page the form leads to")
        }
    }

    /// WEBKIT-GAPS gap 113: a new process on the persisted worker registration, with a prelude changed as a Lilo update changes it.
    func testBitwardenRunsTheNewPreludeAfterARelaunch() async throws {
        let mark = try XCTUnwrap(fixture.preludeMark, "the fixture names the changed prelude's mark")
        let (window, registry) = try makeWindow()
        await registry.restore()
        XCTAssertNotNil(registry.context(for: Self.bitwarden), "Bitwarden is restored from the first process")
        _ = await registry.backgrounds.load(Self.bitwarden)
        let ranNewPrelude = await pollUntil(timeout: 20) {
            let consoles = registry.backgroundDiagnosticsSnapshots().first { $0["id"] as? String == Self.bitwarden }?["pageDiagnostics"] as? [[String: Any]] ?? []
            return consoles.contains { ($0["message"] as? String)?.contains("lilo-e2e-prelude \(mark)") == true }
        }
        await expect(ranNewPrelude, "the relaunched worker runs the new prelude, not the one WebKit cached", nil, registry)

        let site = try await startSite()
        _ = try await openPage(window, try XCTUnwrap(URL(string: "http://127.0.0.1:\(site.port)/login")))
        let popup = try await openPopup(window, registry)
        // Locked or not, past its loading spinner: a worker stuck in its state migrations never gets there.
        let settled = await holds("return !document.getElementById('loading') && !!($('input[name=masterPassword]') || \(itemShown));", in: popup, timeout: 40)
        await expect(settled, "the popup shows the vault or its lock, not a spinner", popup, registry)
        _ = await run("const field = $('input[name=masterPassword]'); if (field) { fill(field, \(literal(fixture.password))); button('Unlock').click(); }", in: popup)
        let shown = await holds("return \(itemShown)", in: popup, timeout: 60)
        await expect(shown, "the popup shows the vault", popup, registry)
    }
}

