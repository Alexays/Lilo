import AppKit
import WebKit
import XCTest
@testable import Lilo

/// An extension page loads in its extension's configuration however its tab reaches it: tab
/// creation, `tabs.create`, reactivation after a discard, its extension loading late, the address
/// bar or `tabs.update`.
@MainActor
final class ExtensionPageTabTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("extension-page-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A window showing an extension's page in its active tab, plus a blank tab to leave it for.
    private func openExtensionPage(permissions: [String] = [], hostPermissions: [String] = []) async throws -> (window: MainWindowController, registry: ProfileExtensionRegistry, extensionId: String, pageURL: URL, tabId: UUID, otherId: UUID) {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        // Installed before a window shows the profile: its restore sweeps folders no record names.
        let registry = try context.profileContexts.context(for: profileId).extensions
        let extDir = try createMinimalExtension(named: "vault", in: tempDir)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0", "permissions": permissions, "host_permissions": hostPermissions]
        try JSONSerialization.data(withJSONObject: manifest).write(to: extDir.appendingPathComponent("manifest.json"))
        try "<title>Vault</title>".write(to: extDir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try await registry.load(from: extDir)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let pageURL = try XCTUnwrap(URL(string: "chrome-extension://\(extensionId)/page.html"))

        let window = makeTestWindow(context, showing: space.id)

        window.createTabStateFirst(url: pageURL)
        let tabId = try XCTUnwrap(window.tabManager.activeTabId)
        let loaded = await pollUntil { window.tabManager.engineTab(for: tabId)?.currentTitle == "Vault" }
        XCTAssertTrue(loaded, "the extension page loads when first opened")
        let other = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        context.browserState.displayedTabIds = [other.id]
        return (window, registry, extensionId, pageURL, tabId, other.id)
    }

    func testDiscardedExtensionPageReloadsWhenReactivated() async throws {
        let (window, _, _, pageURL, tabId, _) = try await openExtensionPage()
        window.tabManager.discardEngines([tabId])
        XCTAssertNil(window.tabManager.engineTab(for: tabId))

        window.activateTabStateFirst(id: tabId)

        let reloaded = await pollUntil { window.tabManager.engineTab(for: tabId)?.currentTitle == "Vault" }
        XCTAssertTrue(reloaded, "a discarded extension page reloads in its extension's configuration")
        XCTAssertEqual(window.tabManager.engineTab(for: tabId)?.currentURL, pageURL, "the extension host is its id")
    }

    func testExtensionPageShownBeforeItsExtensionLoadsReloadsOnceItDoes() async throws {
        let (window, registry, extensionId, _, tabId, _) = try await openExtensionPage()
        await registry.disable(extensionId: extensionId)
        window.tabManager.discardEngines([tabId])
        window.activateTabStateFirst(id: tabId)
        XCTAssertNotNil(window.tabManager.engineTab(for: tabId), "the tab gets an engine before its extension is back")

        try await registry.enable(extensionId: extensionId)

        let reloaded = await pollUntil { window.tabManager.engineTab(for: tabId)?.currentTitle == "Vault" }
        XCTAssertTrue(reloaded, "the page reloads once its extension loads")
    }

    func testTypingAnExtensionPageURLLoadsIt() async throws {
        let (window, _, _, pageURL, _, _) = try await openExtensionPage()
        let handler = TabBridgeHandler(tabManager: window.tabManager, windowController: window, stateCommandHandler: window.applyBrowserCommand)
        let message = try XCTUnwrap(BridgeMessage(dictionary: ["action": "navigate", "payload": ["url": pageURL.absoluteString]]))

        _ = await handler.handle(message: message)

        let tabId = try XCTUnwrap(window.tabManager.activeTabId)
        let loaded = await pollUntil { window.tabManager.engineTab(for: tabId)?.currentTitle == "Vault" }
        XCTAssertTrue(loaded, "a typed extension page URL loads")
    }

    func testExtensionNavigatingAWebTabToItsPageLoadsIt() async throws {
        let (window, registry, extensionId, pageURL, _, otherId) = try await openExtensionPage()
        let adapter = try XCTUnwrap(window.tabManager.tabAdapter(for: otherId))
        let context = try XCTUnwrap(registry.context(for: extensionId))

        adapter.loadURL(pageURL, for: context) { _ in }

        let loaded = await pollUntil { window.tabManager.engineTab(for: otherId)?.currentTitle == "Vault" }
        XCTAssertTrue(loaded, "tabs.update to an extension page loads it in the web tab")
    }

    func testTabsCreateFromAnExtensionPageLoadsItsPage() async throws {
        let (window, _, _, pageURL, tabId, _) = try await openExtensionPage()
        let page = try XCTUnwrap(window.tabManager.engineTab(for: tabId)?.view as? WKWebView)
        let tabsBefore = Set(window.tabManager.openTabs.map(\.id))

        _ = try? await page.callAsyncJavaScript("await chrome.tabs.create({ url: 'page.html' })", contentWorld: .page)

        let opened = await pollUntil {
            window.tabManager.openTabs.contains { !tabsBefore.contains($0.id) && window.tabManager.engineTab(for: $0.id)?.currentTitle == "Vault" }
        }
        XCTAssertTrue(opened, "chrome.tabs.create opens the extension page in its extension's configuration")
        XCTAssertTrue(window.tabManager.openTabs.contains { $0.url == pageURL && !tabsBefore.contains($0.id) })
    }

    func testAnExtensionActivatesThenClosesATab() async throws {
        let (window, registry, extensionId, _, tabId, otherId) = try await openExtensionPage()
        let context = try XCTUnwrap(registry.context(for: extensionId))
        let adapter = try XCTUnwrap(window.tabManager.tabAdapter(for: tabId))
        XCTAssertEqual(window.tabManager.activeTabId, otherId)

        var activateError: Error?
        adapter.activate(for: context) { activateError = $0 }
        XCTAssertNil(activateError)
        XCTAssertEqual(window.tabManager.activeTabId, tabId)

        var closeError: Error?
        adapter.close(for: context) { closeError = $0 }
        XCTAssertNil(closeError)
        let closed = await pollUntil { window.tabManager.tab(for: tabId) == nil }
        XCTAssertTrue(closed, "tabs.remove closes the tab in the window that holds it")
    }

    func testAWindowsCreatePopupIsListedAmongTheExtensionViews() async throws {
        let (_, registry, extensionId, pageURL, _, _) = try await openExtensionPage()
        let context = try XCTUnwrap(registry.context(for: extensionId))
        let panel = try XCTUnwrap(registry.delegate.presentExtensionPanel(
            url: pageURL, type: .popup, for: context, controller: registry.controller, size: NSSize(width: 360, height: 600)
        ))
        defer { panel.nsWindow?.close() }
        let router = browserContext.context.engineFactory.gapRouter

        let shown = await pollUntil { (registry.delegate.extensionViews(of: context).first?.url) == pageURL }
        let (views, error) = await router.route(
            namespace: "runtime", method: "extensionViews", params: [:], extensionId: extensionId, fromWorker: true, registry: registry
        )

        XCTAssertTrue(shown)
        XCTAssertNil(error)
        XCTAssertEqual(views as? [[String: String]], [["contextType": "TAB", "url": pageURL.absoluteString]])
    }

    /// Saladict's startup measure: a normal window and a panel, created then removed, are windows of their own.
    func testANormalWindowsCreateOpensItsOwnWindowAndRemovingItLeavesTheUsersOne() async throws {
        let (window, _, _, _, tabId, _) = try await openExtensionPage()
        let page = try XCTUnwrap(window.tabManager.engineTab(for: tabId)?.view as? WKWebView)
        let spaceId = try XCTUnwrap(window.tabManager.currentSpaceId)
        let tabsBefore = window.tabManager.openTabs.map(\.id)
        let browserWindows = browserContext.context.windows.windows.count

        let created = try await page.callAsyncJavaScript("""
            const current = await chrome.windows.getCurrent();
            const t = await chrome.windows.create({ state: 'maximized' });
            const n = await chrome.windows.create({ state: 'maximized', type: 'panel' });
            await chrome.windows.update(current.id, { focused: true });
            const [got, gotPanel] = await Promise.all([chrome.windows.get(t.id, { populate: true }), chrome.windows.get(n.id)]);
            await chrome.windows.remove(t.id);
            await chrome.windows.remove(n.id);
            const after = (await chrome.windows.getAll()).map(({ id }) => id);
            return JSON.stringify({ ids: [current.id, t.id, n.id, got.id, gotPanel.id], type: got.type, tabs: got.tabs.length, after });
            """, contentWorld: .page) as? String
        let reply = try XCTUnwrap(created.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        let ids = try XCTUnwrap(reply["ids"] as? [Int])

        XCTAssertEqual(Set(ids.prefix(3)).count, 3, "each created window has a new id")
        XCTAssertEqual(Array(ids.suffix(2)), [ids[1], ids[2]])
        XCTAssertEqual(reply["type"] as? String, "normal")
        XCTAssertEqual(reply["tabs"] as? Int, 1, "the window holds the one tab it opened")
        XCTAssertEqual(reply["after"] as? [Int], [ids[0]], "only the user's window is left")
        XCTAssertEqual(browserContext.context.windows.windows.count, browserWindows)
        XCTAssertTrue(browserContext.context.windows.windows.contains { $0 === window }, "the user's window stays open")
        XCTAssertEqual(window.tabManager.currentSpaceId, spaceId)
        XCTAssertEqual(window.tabManager.openTabs.map(\.id), tabsBefore, "the user's tabs are untouched")
        let panelsClosed = await pollUntil { !NSApp.windows.contains { $0.isVisible && $0.contentView is WKWebView } }
        XCTAssertTrue(panelsClosed, "the created windows are gone")
    }

    /// With "Prefer a single window" on, a normal window opens as tabs of the current one, and removing it closes those tabs only.
    func testASingleWindowWindowsCreateRemovesOnlyTheTabsItOpened() async throws {
        let (window, _, _, _, tabId, _) = try await openExtensionPage()
        window.context.settingsStore.set("singleWindow", value: "true")
        let page = try XCTUnwrap(window.tabManager.engineTab(for: tabId)?.view as? WKWebView)
        let tabsBefore = window.tabManager.openTabs.map(\.id)

        let created = try await page.callAsyncJavaScript("""
            const current = await chrome.windows.getCurrent();
            const t = await chrome.windows.create({});
            await chrome.windows.remove(t.id);
            const again = await chrome.windows.remove(t.id).then(() => 'removed', () => 'failed');
            return JSON.stringify([current.id === t.id, again]);
            """, contentWorld: .page) as? String

        XCTAssertEqual(created, "[true,\"failed\"]", "a second remove has no tab left to close, and never closes the window")
        let closed = await pollUntil { window.tabManager.openTabs.map(\.id) == tabsBefore }
        XCTAssertTrue(closed, "the tab the window opened closes, the user's stay")
        XCTAssertTrue(browserContext.context.windows.windows.contains { $0 === window }, "the user's window stays open")
    }

    func testAWindowsCreatePopupLoadsAWebPageInItsTab() async throws {
        let server = try await TinyHTTPServer(index: "<title>Sign in</title>")
        let pageURL = "http://127.0.0.1:\(server.port)/"
        let (window, _, _, _, tabId, _) = try await openExtensionPage(permissions: ["tabs"], hostPermissions: ["<all_urls>"])
        let page = try XCTUnwrap(window.tabManager.engineTab(for: tabId)?.view as? WKWebView)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))

        let created = try await page.callAsyncJavaScript("""
            const { id } = await chrome.windows.create({ type: 'popup', focused: true, url, width: 626, height: 702 });
            await chrome.windows.update(id, { top: 40, left: 60 });
            await chrome.windows.update(id, { focused: true });
            const { type } = await chrome.windows.get(id);
            const blank = await chrome.windows.create({ type: 'popup', focused: false });
            return JSON.stringify({ id, type, blank: [blank.type, blank.tabs.length] });
            """, arguments: ["url": pageURL], contentWorld: .page) as? String
        let popups = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.contentView is WKWebView }
        defer { popups.forEach { $0.close() } }
        let reply = try XCTUnwrap(created.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        let id = try XCTUnwrap(reply["id"] as? Int)

        XCTAssertEqual(reply["type"] as? String, "popup")
        XCTAssertEqual(reply["blank"] as? [AnyHashable], ["popup", 1], "a popup without a url holds a blank tab")
        XCTAssertEqual(popups.count, 2)
        let loaded = await pollUntil { popups.contains { ($0.contentView as? WKWebView)?.title == "Sign in" } }
        XCTAssertTrue(loaded, "the popup window loads the page it was created with")
        let tabURL = try await page.callAsyncJavaScript(
            "return (await chrome.windows.get(id, { populate: true })).tabs.map((tab) => tab.url)",
            arguments: ["id": id], contentWorld: .page
        ) as? [String]
        XCTAssertEqual(tabURL, [pageURL])
    }

    func testTabsDiscardDropsABackgroundTabButNeverTheOneOnScreen() async throws {
        let (window, registry, extensionId, _, tabId, otherId) = try await openExtensionPage()
        window.setupExtensions()
        let router = browserContext.context.engineFactory.gapRouter
        func discard(_ id: UUID) async throws -> String? {
            let page = try XCTUnwrap(window.tabManager.engineTab(for: id)?.view as? WKWebView)
            let position = try XCTUnwrap(registry.tabPosition(of: page, extensionId: extensionId))
            return await router.route(
                namespace: "tabs", method: "discard", params: ["tabs": [position]], extensionId: extensionId, fromWorker: true, registry: registry
            ).error
        }

        let backgroundError = try await discard(tabId)
        let onScreenError = try await discard(otherId)

        XCTAssertNil(backgroundError, "no permission is needed, as in Chrome")
        XCTAssertNil(window.tabManager.engineTab(for: tabId))
        XCTAssertNotNil(window.tabManager.tab(for: tabId), "the tab stays, without its page")
        XCTAssertNotNil(onScreenError)
        XCTAssertNotNil(window.tabManager.engineTab(for: otherId))
    }

    func testATabTheExtensionMayNotAccessHasNoURLOrTitle() async throws {
        let (window, _, _, pageURL, tabId, _) = try await openExtensionPage()
        window.setupExtensions()
        let page = try XCTUnwrap(window.tabManager.engineTab(for: tabId)?.view as? WKWebView)

        let listed = try await page.callAsyncJavaScript("""
            const queried = await chrome.tabs.query({});
            const { tabs } = await chrome.windows.getCurrent({ populate: true });
            return JSON.stringify([...queried, ...tabs].map(({ url, title }) => ({ url, title })));
            """, contentWorld: .page) as? String

        // Eye Dropper's popup parses the url of the active tab unless it is missing.
        let own = "{\"url\":\"\(pageURL.absoluteString)\",\"title\":\"Vault\"}"
        XCTAssertEqual(listed, "[\(own),{},\(own),{}]", "as in Chrome, the blank tab has neither")
    }

    /// A window of a new profile with an extension made of `files` loaded and its worker running.
    private func loadClosingExtension(_ files: [String: String]) async throws -> (window: MainWindowController, registry: ProfileExtensionRegistry, id: String) {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let registry = try context.profileContexts.context(for: profileId).extensions
        let extDir = tempDir.appendingPathComponent("closing")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: extDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let window = makeTestWindow(context, showing: space.id)
        window.createTabStateFirst(url: URL(string: "about:blank"))
        let loaded = await registry.backgrounds.load(id)
        XCTAssertTrue(loaded)
        return (window, registry, id)
    }

    /// An action popup has no current tab, as in Chrome, where WebKit answers the active tab: Proton Pass then sized
    /// its popup to the viewport, and it collapsed. The popup's own page in a tab is that tab.
    func testAnActionPopupHasNoCurrentTabAndKeepsItsSize() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        let extDir = tempDir.appendingPathComponent("sized")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        for (name, content) in [
            "manifest.json": #"{"manifest_version": 3, "name": "Sized", "version": "1.0", "description": "d", "action": {"default_popup": "popup.html"}}"#,
            "popup.html": "<style>html, body { margin: 0; width: var(--width, 420px); height: var(--height, 300px); }</style><script src='popup.js'></script>",
            // As Proton Pass: a page shown in a tab fills it.
            "popup.js": """
                Promise.all([browser.tabs.getCurrent(), chrome.tabs.getCurrent()]).then(([viaBrowser, viaChrome]) => {
                  if (viaBrowser) for (const name of ['--width', '--height']) document.documentElement.style.setProperty(name, '100%');
                  document.title = [viaBrowser, viaChrome].map((tab) => (tab ? 'tab' : 'none')).join(' ');
                });
                """
        ] {
            try content.write(to: extDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        let page = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        window.activateTabStateFirst(id: page.id)
        let adapter = window.tabManager.tabAdapter(for: page.id)
        // A popover shows only from a window on screen.
        window.window?.orderFront(nil)
        defer { window.window?.orderOut(nil) }

        let button = NSMenuItem()
        button.representedObject = id
        window.openExtensionFromMenu(button)
        let shown = await pollUntil { context.action(for: adapter)?.popupWebView?.title == "none none" }
        let popover = context.action(for: adapter)?.popupPopover
        defer { popover?.close() }
        let sized = await pollUntil(timeout: 5) { popover?.contentSize == NSSize(width: 420, height: 300) }

        XCTAssertTrue(shown, "the popup reads no current tab")
        XCTAssertTrue(sized, "the popup keeps its size: \(String(describing: popover?.contentSize))")
        let asTab = try XCTUnwrap(window.createTabStateFirst(url: context.baseURL.appendingPathComponent("popup.html")))
        let read = await pollUntil { window.tabManager.engineTab(for: asTab.id)?.currentTitle == "tab tab" }
        XCTAssertTrue(read, "the popup's page in a tab reads that tab")
    }

    /// A credentialed fetch to a host the extension may access carries the site's SameSite=Lax and Strict cookies, as
    /// in Chrome, where WebKit leaves them out of an extension's request (ChatGPT's side panel read signed out).
    func testCredentialedFetchesCarryTheSiteCookiesAsInChrome() async throws {
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET /set ") {
                return ("200 OK", ["Content-Type: text/html", "Set-Cookie: plain=1; Path=/", "Set-Cookie: lax=1; Path=/; SameSite=Lax", "Set-Cookie: strict=1; Path=/; SameSite=Strict"], Data("<title>set</title>".utf8))
            }
            let cookie = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("cookie:") }.map(String.init) ?? "no cookie"
            return ("200 OK", ["Content-Type: text/plain"], Data(cookie.utf8))
        }
        let (window, registry) = try browserContext.makeExtensionWindow()
        let extDir = tempDir.appendingPathComponent("cookies")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        for (name, content) in [
            "manifest.json": #"{"manifest_version": 3, "name": "Cookies", "version": "1.0", "description": "d", "action": {}, "host_permissions": ["http://127.0.0.1/*"], "background": {"service_worker": "worker.js"}}"#,
            "worker.js": "chrome.runtime.onMessage.addListener((url, _, reply) => { fetch(url, { credentials: 'include', cache: 'no-store' }).then((r) => r.text()).then(reply, (e) => reply('fails ' + e)); return true; });",
            "page.html": "<title>page</title>"
        ] {
            try content.write(to: extDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        _ = await registry.backgrounds.load(id)
        let site = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/set")))
        _ = await pollUntil { window.tabManager.engineTab(for: site.id)?.currentTitle == "set" }
        let pageTab = try XCTUnwrap(window.createTabStateFirst(url: context.baseURL.appendingPathComponent("page.html")))
        _ = await pollUntil { window.tabManager.engineTab(for: pageTab.id)?.currentTitle == "page" }
        let page = try XCTUnwrap(window.tabManager.engineTab(for: pageTab.id)?.view as? WKWebView)
        let echo = "http://127.0.0.1:\(server.port)/echo"
        let fromPage = try await page.callAsyncJavaScript("return await fetch(url, { credentials: 'include', cache: 'no-store' }).then((r) => r.text(), (e) => 'fails ' + e)", arguments: ["url": echo], in: nil, contentWorld: .page)
        let fromWorker = try await page.callAsyncJavaScript("return await chrome.runtime.sendMessage(url)", arguments: ["url": echo], in: nil, contentWorld: .page)
        let siteTab = try XCTUnwrap(window.tabManager.engineTab(for: site.id)?.view as? WKWebView)
        let fromSite = try await siteTab.callAsyncJavaScript("return await fetch('/echo', { cache: 'no-store' }).then((r) => r.text())", arguments: [:], in: nil, contentWorld: .page)
        let cookies = { (echoed: Any?) in Set(((echoed as? String) ?? "").replacingOccurrences(of: "Cookie: ", with: "").components(separatedBy: "; ")) }
        XCTAssertEqual(cookies(fromSite), ["lax=1", "plain=1", "strict=1"])
        XCTAssertEqual(cookies(fromPage), ["lax=1", "plain=1", "strict=1"], "an extension page's fetch")
        XCTAssertEqual(cookies(fromWorker), ["lax=1", "plain=1", "strict=1"], "the worker's fetch")
    }

    /// A window always has an active tab, as in Chrome: Dashlane's popup read `[0].url` of `tabs.query({active, currentWindow})`
    /// and showed an empty vault when the window showed no web page. A terminal on screen has a stand-in tab, a new tab with `tabs`.
    func testAnActionPopupFindsTheActiveTabOfAWindowShowingATerminal() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        let extDir = tempDir.appendingPathComponent("active")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        for (name, content) in [
            "manifest.json": #"{"manifest_version": 3, "name": "Active", "version": "1.0", "description": "d", "permissions": ["tabs"], "action": {"default_popup": "popup.html"}}"#,
            "popup.html": "<script src='popup.js'></script>",
            "popup.js": """
                const shown = (tabs) => tabs.map((tab) => `${tab.active} ${tab.url ?? 'none'}`).join();
                Promise.all([chrome.tabs.query({ active: true, currentWindow: true }), chrome.tabs.query({ active: true, lastFocusedWindow: true })])
                  .then(([current, focused]) => { document.title = `${shown(current)} / ${shown(focused)}`; });
                """
        ] {
            try content.write(to: extDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        let page = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        window.activateTabStateFirst(id: page.id)
        _ = try XCTUnwrap(window.createTerminalTab(activate: true))
        let standIn = try XCTUnwrap(window.tabManager.windowAdapter?.activeTab)
        XCTAssertNil(standIn.engineTab, "the terminal, not the web tab left behind, is the active tab")
        window.window?.orderFront(nil)
        defer { window.window?.orderOut(nil) }

        let button = NSMenuItem()
        button.representedObject = id
        window.openExtensionFromMenu(button)
        var title: String?
        let shown = await pollUntil {
            title = context.action(for: standIn)?.popupWebView?.title
            return title?.isEmpty == false
        }
        context.action(for: standIn)?.popupPopover?.close()

        XCTAssertTrue(shown, "the popup opens")
        XCTAssertEqual(title, "true chrome://newtab/ / true chrome://newtab/")
    }

    /// Chrome runs nothing of a page after its window.close(): neither an API callback or promise it
    /// asked for next (Google Dictionary) nor the port disconnect the close itself causes (DuckDuckGo).
    func testAnExtensionPageRunsNothingAfterItsWindowClose() async throws {
        let (window, registry, id) = try await loadClosingExtension([
            "manifest.json": #"{"manifest_version": 3, "name": "Closing", "version": "1.0", "description": "Closes its page", "permissions": ["storage"], "background": {"service_worker": "worker.js"}}"#,
            "worker.js": "chrome.runtime.onConnect.addListener(port => port.postMessage('close'));",
            "page.html": "<title>Closing</title><script src='page.js'></script>",
            "page.js": """
                const port = chrome.runtime.connect();
                port.onDisconnect.addListener(() => { throw new Error('onDisconnect ran after window.close()'); });
                port.onMessage.addListener(() => {
                    window.close();
                    chrome.storage.local.get('options', () => { throw new Error('a callback ran after window.close()'); });
                    chrome.storage.local.get('options').then(() => { throw new Error('a promise ran after window.close()'); });
                });
                """
        ])
        let context = try XCTUnwrap(registry.context(for: id))

        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "chrome-extension://\(id)/page.html")))

        let closed = await pollUntil { window.tabManager.tab(for: tab.id) == nil }
        XCTAssertTrue(closed, "window.close() closes the page's tab")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(context.errors.map(\.localizedDescription), [])
    }

    /// Messages posted on a port before it connects arrive once each, a repeated one included, where
    /// WebKit delivers them twice (WEBKIT-GAPS.md, gap 43).
    func testPortMessagesSentBeforeTheConnectionArriveOnce() async throws {
        let (window, registry, id) = try await loadClosingExtension([
            "manifest.json": #"{"manifest_version": 3, "name": "Ports", "version": "1.0", "action": {"default_title": "waiting"}, "background": {"service_worker": "worker.js"}}"#,
            "worker.js": """
                let received = 0;
                chrome.runtime.onConnect.addListener((port) => {
                    port.onMessage.addListener(() => { received++; });
                    port.postMessage('state');
                });
                chrome.runtime.onMessage.addListener((count) => { chrome.action.setTitle({ title: `${received} ${count}` }); });
                """,
            "page.html": "<script src='page.js'></script>",
            "page.js": """
                let answers = 0;
                const port = chrome.runtime.connect();
                port.onMessage.addListener(() => { answers++; });
                port.postMessage('state?');
                port.postMessage('state?');
                setTimeout(() => chrome.runtime.sendMessage(answers), 500);
                """
        ])
        let context = try XCTUnwrap(registry.context(for: id))

        window.createTabStateFirst(url: URL(string: "chrome-extension://\(id)/page.html"))

        await pollUntil { context.action(for: nil)?.label != "waiting" }
        XCTAssertEqual(context.action(for: nil)?.label, "2 1", "the worker gets both requests once, the page one answer")
    }

    /// WebKit's own executeScript, under way on a tab that closes itself, ends without taking the app
    /// down: Lilo closes such a page and never suspends it (WEBKIT-GAPS.md, gap 5).
    func testExecuteScriptOnATabThatClosesItselfEnds() async throws {
        let server = try await TinyHTTPServer(index: "<title>Closing</title><script>setTimeout(() => window.close(), 300)</script>")
        let (window, registry, id) = try await loadClosingExtension([
            "manifest.json": #"{"manifest_version": 3, "name": "Scripting", "version": "1.0", "description": "Scripts a closing tab", "permissions": ["scripting", "tabs"], "host_permissions": ["http://127.0.0.1/*"], "action": {"default_title": "waiting"}, "background": {"service_worker": "worker.js"}}"#,
            "worker.js": """
                const scripted = new Set();
                chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
                    if (!tab.url?.startsWith('http://127.0.0.1') || scripted.has(tabId)) return;
                    scripted.add(tabId);
                    const run = () => chrome.scripting.executeScript({ target: { tabId }, func: () => document.title })
                        .then(run, () => chrome.action.setTitle({ title: 'ended' }));
                    run();
                });
                """
        ])
        let context = try XCTUnwrap(registry.context(for: id))

        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))

        let closed = await pollUntil { window.tabManager.tab(for: tab.id) == nil }
        XCTAssertTrue(closed, "window.close() closes the tab")
        let ended = await pollUntil { context.action(for: nil)?.label == "ended" }
        XCTAssertTrue(ended, "executeScript on the closed tab rejects")
    }
}
