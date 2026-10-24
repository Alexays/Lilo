import JavaScriptCore
import WebKit
import XCTest
@testable import Lilo

/// Reproduces the WebKit gaps of docs/WEBKIT-GAPS.md, mostly in a bare WKWebExtensionController: a
/// failure means WebKit changed, and its message names the Lilo workaround to remove.
@MainActor
final class WebKitGapTests: XCTestCase {
    private var directory: URL!
    private var controller: WKWebExtensionController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("webkit-gaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = WKWebExtensionController(configuration: .nonPersistent())
    }

    override func tearDown() {
        for context in controller.extensionContexts { try? controller.unload(context) }
        controller = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Writes `manifest` and `files` into a new folder and returns it.
    private func writeExtension(_ manifest: [String: Any], files: [String: String] = [:]) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        for (name, source) in files { try source.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return folder
    }

    /// Loads `worker` as the service worker of an extension in the bare controller, every requested
    /// permission granted, and returns the action title it sets ("waiting" if it sets none in time).
    private func bareWorkerTitle(
        _ worker: String, permissions: [String] = [], files: [String: String] = [:], manifest extra: [String: Any] = [:]
    ) async throws -> String? {
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Gap", "version": "1.0", "permissions": permissions,
            "host_permissions": ["<all_urls>"], "action": ["default_title": "waiting"],
            "background": ["service_worker": "background.js"]
        ].merging(extra) { $1 }
        let folder = try writeExtension(manifest, files: files.merging(["background.js": worker]) { $1 })
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        context.webExtension.allRequestedMatchPatterns.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        context.loadBackgroundContent { _ in }
        // The worker's title is its outcome. The bound only stops a hang: compiling a ruleset near
        // WebKit's 150000-rule cap takes over 30 s on a machine busy with parallel test runs.
        await pollUntil(timeout: 120) { context.action(for: nil)?.label != "waiting" }
        return context.action(for: nil)?.label
    }

    /// Loads an extension with `worker` as its service worker and an empty page.html, opens the page in a
    /// web view of the bare controller, and returns what `pageScript` returns there.
    private func barePageResult(worker: String, workerPath: String = "background.js", pageScript: String) async throws -> String? {
        let folder = try writeExtension([
            "manifest_version": 3, "name": "Gap", "version": "1.0", "background": ["service_worker": workerPath]
        ], files: ["page.html": "<p>page</p>"])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(workerPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try worker.write(to: folder.appendingPathComponent(workerPath), atomically: true, encoding: .utf8)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        context.loadBackgroundContent { _ in }
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        await pollUntil { (try? await page.evaluateJavaScript("document.readyState + location.pathname")) as? String == "complete/page.html" }
        return try await page.callAsyncJavaScript(pageScript, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    func testRuntimeMembersAreOwnPropertiesNothingRedefines() async throws {
        let title = try await bareWorkerTitle("""
        const report = ['connectNative', 'lastError', 'onInstalled'].map((name) => {
          const own = Object.hasOwn(browser.runtime, name);
          try { Object.defineProperty(browser.runtime, name, { value: 'lilo', configurable: true }); } catch { return `${name}:throws`; }
          return `${name}:${own ? 'own' : 'inherited'}:${browser.runtime[name] === 'lilo' ? 'redefined' : 'kept'}`;
        });
        chrome.action.setTitle({ title: report.join(' ') });
        """, permissions: ["nativeMessaging"])
        XCTAssertEqual(
            title, "connectNative:own:kept lastError:own:kept onInstalled:own:kept",
            "WebKit's runtime members can now be redefined: chrome.runtime can take Lilo's members on the prototype instead of the view and stand-ins (chrome-compat.ts serve and standIns)"
        )
    }

    func testEventsStopOnceNeitherGlobalIsTheNamespace() async throws {
        let worker = { (replaced: String) in """
        const namespace = browser;
        \(replaced)
        namespace.storage.onChanged.addListener(() => namespace.action.setTitle({ title: 'changed' }));
        namespace.storage.local.set({ key: 1 });
        setTimeout(() => namespace.action.setTitle({ title: 'silent' }), 1000);
        """ }
        let browserOnly = try await bareWorkerTitle(worker("globalThis.browser = new Proxy(namespace, {});"), permissions: ["storage"])
        let both = try await bareWorkerTitle(worker("globalThis.browser = new Proxy(namespace, {}); globalThis.chrome = new Proxy(namespace, {});"), permissions: ["storage"])

        XCTAssertEqual(browserOnly, "changed", "WebKit falls back to globalThis.chrome")
        XCTAssertEqual(
            both, "silent",
            "WebKit no longer finds its namespace through globalThis.browser and chrome to fire events: Lilo can serve its view of runtime through browser too (chrome-compat.ts)"
        )
    }

    func testEventsLackHasListeners() async throws {
        let title = try await bareWorkerTitle("chrome.action.setTitle({ title: typeof browser.runtime.onMessage.hasListeners });")
        XCTAssertEqual(title, "undefined", "WebKit's events now have hasListeners: drop chromeEvent.add.hasListeners (chrome-leniency.ts)")
    }

    func testContextMenusRejectMV2ActionContexts() async throws {
        let title = try await bareWorkerTitle("""
        try {
          browser.contextMenus.create({ id: 'item', title: 'Item', contexts: ['browser_action'] }, () => {
            chrome.action.setTitle({ title: browser.runtime.lastError?.message ?? 'accepted' });
          });
        } catch (error) { chrome.action.setTitle({ title: `throws: ${error.message}` }); }
        """, permissions: ["contextMenus"])
        XCTAssertTrue(
            title?.contains("browser_action") == true,
            "WebKit now accepts the MV2 action contexts (\(title ?? "nil")): drop contextMenusPatches (chrome-leniency.ts)"
        )
    }

    func testPermissionsRejectNamesWebKitDoesNotKnow() async throws {
        let title = try await bareWorkerTitle("""
        try {
          browser.permissions.contains({ permissions: ['tabGroups'] }).then(
            (result) => chrome.action.setTitle({ title: `resolved ${result}` }),
            (error) => chrome.action.setTitle({ title: error.message }));
        } catch (error) { chrome.action.setTitle({ title: `throws: ${error.message}` }); }
        """)
        XCTAssertTrue(
            title?.contains("'tabGroups' is not a valid permission") == true,
            "WebKit now answers for a permission it does not know (\(title ?? "nil")): drop withoutUnknownPermissions (chrome-leniency.ts)"
        )
    }

    func testRequestedPermissionsDropPrivacy() async throws {
        let folder = try writeExtension(["manifest_version": 3, "name": "Gap", "version": "1.0", "permissions": ["privacy", "storage"]])
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        XCTAssertTrue(webExtension.requestedPermissions.contains(.storage))
        XCTAssertFalse(
            webExtension.requestedPermissions.contains(WKWebExtension.Permission(rawValue: "privacy")),
            "WebKit now keeps the privacy permission: install-gap-apis.ts can read it from the granted permissions"
        )
    }

    func testWebRequestFiltersRejectUnknownTypesAndSchemes() async throws {
        let title = try await bareWorkerTitle("""
        const attempt = (filter) => {
          try { browser.webRequest.onBeforeRequest.addListener(() => {}, filter); return 'accepted'; } catch (error) { return error.message; }
        };
        chrome.action.setTitle({ title: [attempt({ urls: ['<all_urls>'], types: ['webbundle'] }), attempt({ urls: ['ws://*/*'] })].join(' | ') });
        """, permissions: ["webRequest"])
        let parts = title?.components(separatedBy: " | ") ?? []
        XCTAssertTrue(
            parts.first?.contains("'webbundle' is an unknown resource type") == true,
            "WebKit now takes a webbundle filter (\(title ?? "nil")): drop the resource type retry of chromeEvent.patch.addListener (chrome-leniency.ts)"
        )
        XCTAssertTrue(
            parts.last?.contains("'ws://*/*' is an invalid match pattern") == true,
            "WebKit now takes a ws:// filter (\(title ?? "nil")): drop the match pattern retry of chromeEvent.patch.addListener (chrome-leniency.ts)"
        )
    }

    func testContextMenusRejectURLPatternsChromeAccepts() async throws {
        let title = try await bareWorkerTitle("""
        const attempt = (patterns) => {
          try { browser.contextMenus.create({ id: patterns[0], title: 'Item', documentUrlPatterns: patterns }); return 'accepted'; } catch (error) { return error.message; }
        };
        chrome.action.setTitle({ title: [attempt(['ftp://*/*']), attempt(['chrome-extension://invalid/*'])].join(' | ') });
        """, permissions: ["contextMenus"])
        let parts = title?.components(separatedBy: " | ") ?? []
        XCTAssertTrue(
            parts.first?.contains("'ftp://*/*' is not a valid pattern") == true,
            "WebKit now takes an ftp:// menu pattern (\(title ?? "nil")): drop the pattern retry of withChromeMenuProperties (chrome-leniency.ts)"
        )
        XCTAssertEqual(parts.last, "accepted", "WebKit rejects the pattern Lilo uses to match nothing (chrome-leniency.ts matchesNothing)")
    }

    func testContextMenusRejectAMissingTitle() async throws {
        let title = try await bareWorkerTitle("""
        try { browser.contextMenus.create({ id: 'item' }); chrome.action.setTitle({ title: 'accepted' }); } catch (error) { chrome.action.setTitle({ title: error.message }); }
        """, permissions: ["contextMenus"])
        XCTAssertTrue(
            title?.contains("missing required keys: 'title'") == true,
            "WebKit no longer throws for a menu item without a title (\(title ?? "nil")): drop the missing title branch of contextMenusPatches.create (chrome-leniency.ts)"
        )
    }

    func testAlarmsCreateTakesNoCallback() async throws {
        let title = try await bareWorkerTitle("""
        const returned = typeof browser.alarms.create('first', { delayInMinutes: 1 });
        try { browser.alarms.create('second', { delayInMinutes: 1 }, () => {}); chrome.action.setTitle({ title: `${returned} | accepted` }); } catch (error) { chrome.action.setTitle({ title: `${returned} | ${error.message}` }); }
        """, permissions: ["alarms"])
        let parts = title?.components(separatedBy: " | ") ?? []
        XCTAssertEqual(parts.first, "undefined", "WebKit's alarms.create now returns a promise: alarmsPatches (chrome-leniency.ts) need not make one")
        XCTAssertTrue(
            parts.last?.contains("The 'info' value is invalid, because an object is expected") == true,
            "WebKit now takes a callback in alarms.create (\(title ?? "nil")): drop the callback of alarmsPatches (chrome-leniency.ts)"
        )
    }

    func testActionRejectsANullTabId() async throws {
        let title = try await bareWorkerTitle("""
        try { browser.action.setTitle({ tabId: null, title: 'accepted' }); } catch (error) { chrome.action.setTitle({ title: error.message }); }
        """)
        XCTAssertTrue(
            title?.contains("'tabId' is expected to be a number, but null was provided") == true,
            "WebKit now takes a null tabId (\(title ?? "nil")): drop actionPatches (chrome-leniency.ts)"
        )
    }

    func testRegisterContentScriptsThrowsWithoutMatches() async throws {
        let title = try await bareWorkerTitle("""
        try {
          browser.scripting.registerContentScripts([{ id: 'script', js: ['script.js'], matches: [] }]).then(
            () => chrome.action.setTitle({ title: 'resolved' }), (error) => chrome.action.setTitle({ title: `rejects: ${error.message}` }));
        } catch (error) { chrome.action.setTitle({ title: `throws: ${error.message}` }); }
        """, permissions: ["scripting"], files: ["script.js": ""])
        XCTAssertTrue(
            title?.hasPrefix("throws: ") == true && title?.contains("must specify at least one match pattern for script with ID 'script'") == true,
            "WebKit now rejects or takes empty matches (\(title ?? "nil")): drop scriptingPatches (chrome-leniency.ts)"
        )
    }

    func testGetMessageOffItsNamespaceReturnsUndefined() async throws {
        let title = try await bareWorkerTitle("""
        chrome.action.setTitle({ title: `${typeof browser.i18n.getMessage('@@extension_id')} | ${typeof browser.i18n.getMessage.call(browser, '@@extension_id')}` });
        """)
        XCTAssertEqual(
            title, "string | undefined",
            "WebKit's getMessage now answers off browser.i18n: drop i18nPatches (chrome-leniency.ts)"
        )
    }

    func testStorageReadsMissWritesInFlight() async throws {
        let title = try await bareWorkerTitle("""
        browser.storage.local.set({ key: 1 });
        browser.storage.local.get('key').then((items) => chrome.action.setTitle({ title: JSON.stringify(items) }));
        """, permissions: ["storage"])
        XCTAssertEqual(title, "{}", "WebKit now orders a read after the writes before it: drop the ordering of shared/storage-area.ts and the storage gap of COMPATIBILITY.md")
    }

    func testSendMessageCallbackWithoutResponseSetsNoLastError() async throws {
        let title = try await bareWorkerTitle("""
        browser.runtime.sendMessage({ ping: 1 }, (response) => chrome.action.setTitle({ title: `${response} ${browser.runtime.lastError}` }));
        """)
        XCTAssertEqual(title, "undefined null", "WebKit now sets lastError for a message no one answers, as Chrome: Video Downloader Professional can leave knownFailures")
    }

    func testWebNavigationRejectsAMissingTab() async throws {
        let title = try await bareWorkerTitle("""
        const outcome = (call) => call.then((value) => `resolved ${JSON.stringify(value)}`, (error) => error.message);
        Promise.all([
          outcome(browser.webNavigation.getAllFrames({ tabId: 987654 })),
          outcome(browser.webNavigation.getFrame({ tabId: 987654, frameId: 0 })),
        ]).then((results) => chrome.action.setTitle({ title: results.join(' | ') }));
        """, permissions: ["webNavigation"])
        let parts = title?.components(separatedBy: " | ") ?? []
        XCTAssertEqual(parts.count, 2, "\(title ?? "nil")")
        for part in parts {
            XCTAssertTrue(
                part.hasSuffix("Tab not found."),
                "WebKit now resolves for a missing tab (\(part)): drop webNavigationPatches (augmentation/webNavigation.ts)"
            )
        }
    }

    func testImportScriptsRunsPendingPromiseCallbacks() async throws {
        let title = try await bareWorkerTitle("""
        self.order = [];
        Promise.resolve().then(() => order.push('callback'));
        importScripts('imported.js');
        order.push('after import');
        Promise.resolve().then(() => order.push('second callback'));
        importScripts('imported.js');
        order.push('after second import');
        setTimeout(() => chrome.action.setTitle({ title: order.join(', ') }), 100);
        """, files: ["imported.js": "order.push('imported');"])
        // A script the worker loaded already runs none, as in Chrome.
        XCTAssertEqual(
            title, "callback, imported, after import, imported, after second import, second callback",
            "WebKit now runs promise callbacks after the worker's top-level code, as Chrome does: drop the importScripts note in COMPATIBILITY.md"
        )
    }

    func testPackagedWasmHasNoWasmMIMEType() async throws {
        let title = try await bareWorkerTitle("""
        fetch('module.wasm').then((response) => chrome.action.setTitle({ title: String(response.headers.get('content-type')) }));
        """, files: ["module.wasm": "\0asm"])
        XCTAssertNotEqual(
            title, "application/wasm",
            "WebKit now serves .wasm as application/wasm: drop shared/wasm-mime.ts"
        )
        XCTAssertNotEqual(title, "waiting", "the worker never answered")
    }

    func testManifestEntriesChromeAcceptsAreRejected() async throws {
        let entries: [(name: String, entry: [String: Any], error: String)] = [
            ("an empty _execute_action", ["commands": ["_execute_action": [String: Any]()]], "Empty or invalid command in the `commands` manifest entry."),
            ("an empty content_security_policy", ["content_security_policy": [String: Any]()], "Empty or invalid `content_security_policy` manifest entry."),
            (
                "a web_accessible_resources entry naming extension_ids only",
                ["web_accessible_resources": [["resources": ["page.html"], "extension_ids": ["abcdefghijklmnopabcdefghijklmnop"]]]],
                "Invalid `web_accessible_resources` manifest entry."
            ),
            ("an empty description", ["description": ""], "Missing or empty `description` manifest entry."),
            ("an empty content_scripts list", ["content_scripts": [Any]()], "Empty or invalid `content_scripts` manifest entry."),
            (
                "a shortcut with spaces around its keys",
                ["commands": ["open": ["description": "Open", "suggested_key": ["default": "Ctrl + Shift + Y"]]]],
                "Invalid `suggested_key` in the `commands` manifest entry."
            ),
            ("externally_connectable <all_urls>", ["externally_connectable": ["matches": ["<all_urls>"]]], "Empty or invalid `externally_connectable` manifest entry."),
            ("an externally_connectable port", ["externally_connectable": ["matches": ["https://example.com:*/*"]]], "Empty or invalid `externally_connectable` manifest entry."),
            ("an empty externally_connectable", ["externally_connectable": [String: Any]()], "Empty or invalid `externally_connectable` manifest entry."),
            (
                "an externally_connectable wildcard on a public suffix",
                ["externally_connectable": ["matches": ["*://*.netlify.app/*"]]], "Empty or invalid `externally_connectable` manifest entry."
            )
        ]
        for (name, entry, error) in entries {
            let manifest = entry.merging(["manifest_version": 3, "name": "Gap", "version": "1.0", "description": "Gap"]) { entry, _ in entry }
            let webExtension = try await WKWebExtension(resourceBaseURL: try writeExtension(manifest))
            XCTAssertEqual(
                webExtension.errors.map(\.localizedDescription), [error],
                "WebKit now accepts \(name): drop its rewrite in ExtensionBackgroundPreparer.acceptAsChrome"
            )
        }
    }

    func testHostPermissionsMatchTheirPath() throws {
        let pattern = try WKWebExtension.MatchPattern(string: "https://*/")
        XCTAssertFalse(
            pattern.matches(try XCTUnwrap(URL(string: "https://example.com/a"))),
            "WebKit now ignores a host permission's path: drop the host_permissions rewrite in ExtensionBackgroundPreparer.acceptAsChrome"
        )
    }

    func testLifecycleEventsDependOnTheControllerAge() async throws {
        let worker = """
        const heard = [];
        const record = (name) => (details) => { heard.push([name, details?.reason].filter(Boolean).join(':')); chrome.action.setTitle({ title: heard.join(' ') }); };
        chrome.runtime.onInstalled.addListener(record('installed'));
        chrome.runtime.onStartup.addListener(record('startup'));
        """
        let early = try await bareWorkerTitle(worker)
        try await Task.sleep(for: .seconds(6))
        let late = try await bareWorkerTitle(worker)
        XCTAssertNotEqual(
            early, late,
            "WebKit now picks onInstalled and onStartup the same way however old its controller is (\(early ?? "nil")): Lilo's lifecycle stand-ins (augmentation/runtime.ts) may go"
        )
        XCTAssertEqual(early, "startup", "a context loaded in the controller's first 5 s")
        XCTAssertEqual(late, "installed:install", "a context loaded after 5 s")
    }

    func testContentScriptsRunInPagesAlreadyOpen() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = controller
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        page.loadHTMLString("<p>open before the extension</p>", baseURL: URL(string: "https://example.com/"))
        await pollUntil { (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" }

        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Gap", "version": "1.0",
            "content_scripts": [["matches": ["https://example.com/*"], "js": ["content.js"]]]
        ]
        let folder = try writeExtension(manifest, files: ["content.js": "document.documentElement.dataset.injected = 'yes';"])
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.webExtension.allRequestedMatchPatterns.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)

        let injected = await pollUntil {
            (try? await page.evaluateJavaScript("document.documentElement.dataset.injected ?? 'no'")) as? String == "yes"
        }
        XCTAssertTrue(injected, "WebKit no longer injects into open pages, as Chrome: drop the note in COMPATIBILITY.md (scripting and tabs)")
    }

    func testRefusedNativeConnectionSetsNoLastError() async throws {
        let refusing = RefusingNativeHosts()
        controller.delegate = refusing
        defer { withExtendedLifetime(refusing) {} }
        let folder = try writeExtension([
            "manifest_version": 3, "name": "Native", "version": "1.0", "action": ["default_title": "waiting"],
            "permissions": ["nativeMessaging"], "background": ["service_worker": "background.js"]
        ], files: ["background.js": """
        browser.runtime.connectNative('com.lilo.missing_host').onDisconnect.addListener(() => {
          browser.action.setTitle({ title: String(browser.runtime.lastError?.message ?? 'no lastError') });
        });
        """])
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        try controller.load(context)
        context.loadBackgroundContent { _ in }
        await pollUntil(timeout: 10) { context.action(for: nil)?.label != "waiting" }

        XCTAssertEqual(
            context.action(for: nil)?.label, "no lastError",
            "WebKit now sets runtime.lastError on a refused native port: drop nativeMessagingAsChrome (chrome-leniency.ts) and the port mark (ExtensionNativeMessaging.swift)"
        )
        XCTAssertFalse(context.errors.isEmpty, "WebKit no longer reports a refused native connection as an extension error: ExtensionNativeMessaging can refuse unmarked ports again")
    }

    func testTabsWithoutHostAccessReportEmptyURLAndTitle() async throws {
        let server = try await TinyHTTPServer(index: "<title>Page</title><p>page</p>")
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))
        let loaded = await pollUntil { window.tabManager.engineTab(for: tab.id)?.currentTitle == "Page" }
        XCTAssertTrue(loaded, "the page loads")

        let folder = try writeExtension([
            "manifest_version": 3, "name": "Tabs", "version": "1.0", "action": [String: Any](),
            "background": ["service_worker": "background.js"]
        ], files: ["background.js": """
        const query = chrome.tabs.query.__liloUnwrapped ?? chrome.tabs.query;
        query.call(chrome.tabs, {}).then((tabs) => chrome.action.setTitle({
          title: tabs.length && tabs.every((tab) => tab.url === '' && tab.title === '') ? 'empty strings' : JSON.stringify(tabs.map((tab) => [tab.url, tab.title])),
        }));
        """])
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        _ = await registry.backgrounds.load(id)
        await pollUntil(timeout: 10) { context.action(for: nil)?.label != "Tabs" }

        XCTAssertEqual(
            context.action(for: nil)?.label, "empty strings",
            "WebKit now leaves out a withheld tab url and title: drop tabURLPatches and windowURLPatches (augmentation/tabs.ts)"
        )
    }

    func testActionHasNoBadgeBackgroundColor() {
        XCTAssertTrue(WKWebExtension.Action.instancesRespond(to: NSSelectorFromString("badgeText")))
        XCTAssertFalse(
            WKWebExtension.Action.instancesRespond(to: NSSelectorFromString("badgeBackgroundColor")),
            "WKWebExtension.Action now exposes badge colors: drop ActionColorBridgeHandler and the action colors of chrome-compat.ts"
        )
    }

    func testContentRuleListsRejectAlternationAndNonASCII() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let rules = [
            (name: "a plain filter", trigger: #"{"url-filter":"ab"}"#, compiles: true),
            (name: "an alternation", trigger: #"{"url-filter":"a|b"}"#, compiles: false),
            (name: "a non-ASCII url-filter", trigger: #"{"url-filter":"exämple"}"#, compiles: false),
            (name: "a non-ASCII domain", trigger: #"{"url-filter":"ab","if-domain":["exämple.com"]}"#, compiles: false)
        ]
        for rule in rules {
            let list = #"[{"trigger":\#(rule.trigger),"action":{"type":"block"}}]"#
            let compiled = (try? await store.compileContentRuleList(forIdentifier: UUID().uuidString, encodedContentRuleList: list)) != nil
            XCTAssertEqual(
                compiled, rule.compiles,
                "WebKit now compiles \(rule.name) differently: revisit dnr-rules.ts and FilterListConverter.swift"
            )
        }
    }

    func testNamespacesDifferFromChromeInShape() async throws {
        let title = try await bareWorkerTitle("""
        const { getManifest } = browser.runtime;
        chrome.action.setTitle({ title: [
          typeof getManifest(),
          Object.keys(browser.storage.local).includes('get'),
          Object.getOwnPropertyDescriptor(browser, 'alarms').writable,
          String(browser.runtime.lastError),
          Object.keys({ ...browser.alarms }).includes('onAlarm'),
        ].join(' ') });
        """, permissions: ["storage", "alarms"])
        let parts = title?.components(separatedBy: " ") ?? []
        XCTAssertEqual(parts.count, 5, "\(title ?? "nil")")
        XCTAssertEqual(parts.first, "undefined", "WebKit's methods now work detached: drop ownMembers (chrome-compat.ts)")
        XCTAssertEqual(parts.dropFirst().first, "false", "WebKit's methods are now own members: drop ownMembers (chrome-compat.ts)")
        XCTAssertEqual(parts.dropFirst(2).first, "false", "WebKit's namespaces are now writable: drop the set trap of Lilo's chrome (chrome-compat.ts)")
        XCTAssertEqual(parts.dropFirst(3).first, "null", "WebKit's lastError is now undefined without an error: drop the lastError view (chrome-compat.ts)")
        XCTAssertEqual(parts.last, "false", "WebKit's events are now copied with their namespace: chrome hands out a view only to serve members (chrome-compat.ts)")
    }

    func testWebSocketStallsTheWorkerLoad() async throws {
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Gap", "version": "1.0", "background": ["service_worker": "background.js"]
        ]
        let folder = try writeExtension(manifest, files: ["background.js": "new WebSocket('ws://127.0.0.1:10007/');"])
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        var answer: String?
        context.loadBackgroundContent { error in answer = String(describing: error) }
        await pollUntil(timeout: 5) { answer != nil }
        XCTAssertNil(answer, "WebKit now loads a worker that opens a WebSocket: NeatDownloadManager can leave knownFailures")
    }

    func testNavigatorCredentialsForgetsWhatAPageSetOnIt() async throws {
        let page = WKWebView()
        page.loadHTMLString("<p>sign in</p>", baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil { page.url != nil && !page.isLoading }
        _ = try await page.evaluateJavaScript("navigator.credentials.get = function hooked() {}; 1")
        for _ in 0..<20 {
            _ = try await page.evaluateJavaScript("for (let i = 0; i < 200000; i++) ({ i }); 1")
            try await Task.sleep(for: .milliseconds(50))
        }
        let name = try await page.evaluateJavaScript("navigator.credentials.get.name") as? String
        XCTAssertEqual(name, "get", "WebKit now keeps navigator.credentials: drop Lilo's page script that holds it")
    }

    func testStorageStoresNonFiniteNumbersAsNull() async throws {
        let title = try await bareWorkerTitle("""
        chrome.storage.session.set({ infinite: Infinity, date: new Date(0) })
          .then(() => chrome.storage.session.get(null))
          .then((items) => chrome.action.setTitle({ title: `${items.infinite} ${typeof items.date}` }));
        """, permissions: ["storage"])
        XCTAssertEqual(
            title, "null string",
            "WebKit now stores values as Chrome does (no non-finite number, a Date as {}): drop withoutNonFiniteNumbers (storage-area.ts) and update COMPATIBILITY.md"
        )
    }

    func testArrowFunctionInForInitializerRejectsIn() throws {
        let context = try XCTUnwrap(JSContext())
        var message: String?
        context.exceptionHandler = { _, exception in message = exception?.toString() }
        context.evaluateScript("for (var f = (e) => { return 1 in e; }, i = 0; i < 1; i++);")
        XCTAssertEqual(
            message?.contains("Unexpected keyword 'in'"), true,
            "JavaScriptCore now parses `in` in an arrow function body inside a for initializer: PreMiD can leave knownFailures"
        )
    }

    func testAssignmentAcrossAnAwaitChecksItsBindingFirst() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var outcome = 'pending';
        (function () {
          async function assign() { return value = await 1; }
          assign().then(() => { outcome = 'assigned'; }, (error) => { outcome = String(error); });
          let value = 0;
        })();
        """)
        XCTAssertEqual(
            context.evaluateScript("outcome")?.toString(), "ReferenceError: Cannot access 'value' before initialization.",
            "JavaScriptCore now checks an assignment's binding once the await is done, as V8: Buyhatke can leave knownFailures"
        )
    }

    func testExtensionContextsLackSharedArrayBuffer() async throws {
        let title = try await bareWorkerTitle("chrome.action.setTitle({ title: typeof SharedArrayBuffer });")
        XCTAssertEqual(title, "undefined", "WebKit now gives extensions SharedArrayBuffer, as Chrome does: update COMPATIBILITY.md (Distill can leave knownFailures)")
    }

    /// A worker that sets its action title to what `call` settles with: "applied" or the error message.
    private func dnrOutcome(_ call: String, files: [String: String] = [:], manifest: [String: Any] = [:]) async throws -> String? {
        try await bareWorkerTitle("""
        const dnr = chrome.declarativeNetRequest;
        (async () => \(call))().then(() => 'applied', (error) => error.message).then((title) => chrome.action.setTitle({ title }));
        """, permissions: ["declarativeNetRequest"], files: files, manifest: manifest)
    }

    func testUpdateEnabledRulesetsCountsRulesetsThatDoNotChange() async throws {
        let title = try await dnrOutcome(
            "dnr.updateEnabledRulesets({ disableRulesetIds: ['off'] })", files: ["rules.json": "[]"],
            manifest: ["declarative_net_request": ["rule_resources": [["id": "off", "enabled": false, "path": "rules.json"]]]]
        )
        XCTAssertTrue(
            title?.contains("exceeds the limit") == true,
            "WebKit now counts only the rulesets that change (\(title ?? "nil")): drop the diff of updateEnabledRulesets (dnr-rules.ts)"
        )
    }

    func testConcurrentDynamicRuleUpdatesRemoveFromStaleRuleIds() async throws {
        let title = try await dnrOutcome("""
        Promise.all([1, 2].map((n) => dnr.updateDynamicRules({
          removeRuleIds: n === 2 ? [1] : [], addRules: [{ id: 1, action: { type: 'block' }, condition: { urlFilter: 'lilo-gap' } }],
        })))
        """)
        XCTAssertTrue(
            title?.contains("does not have a unique ID") == true,
            "WebKit now removes rules a pending update adds (\(title ?? "nil")): drop the update queue of dnr-rules.ts"
        )
    }

    func testRulesetOverWebKitsRuleCapDoesNotApply() async throws {
        // WebKit expands a rule into one content blocker rule per request domain, and compiles at most 150000.
        let domains = (0...150_000).map { "\"d\($0).example\"" }.joined(separator: ",")
        let title = try await dnrOutcome(
            "dnr.updateEnabledRulesets({ enableRulesetIds: ['big'] })",
            files: ["rules.json": #"[{"id":1,"action":{"type":"block"},"condition":{"requestDomains":[\#(domains)]}}]"#],
            manifest: ["declarative_net_request": ["rule_resources": [["id": "big", "enabled": false, "path": "rules.json"]]]]
        )
        // A compile that outlasts the bound proves nothing either way, as on a slow CI runner.
        if title == "waiting" { throw XCTSkip("WebKit was still compiling the ruleset after 120 s") }
        XCTAssertTrue(
            title?.hasSuffix("Failed to apply rules.") == true,
            "WebKit now applies a ruleset past its rule cap (\(title ?? "nil")): drop the static rule budget of webKitStaticRulesets (dnr-rules.ts)"
        )
    }

    func testTurningOffEveryRulesetFailsDuringTheFirstCompile() async throws {
        // The first compile of a ruleset this big takes seconds; until it ends there is no compiled file to delete.
        let domains = (0..<140_000).map { "\"d\($0).example\"" }.joined(separator: ",")
        let title = try await dnrOutcome(
            "dnr.updateEnabledRulesets({ disableRulesetIds: ['big'] })",
            files: ["rules.json": #"[{"id":1,"action":{"type":"block"},"condition":{"requestDomains":[\#(domains)]}}]"#],
            manifest: ["declarative_net_request": ["rule_resources": [["id": "big", "enabled": true, "path": "rules.json"]]]]
        )
        // A compile that outlasts the bound proves nothing either way, as on a slow CI runner.
        if title == "waiting" { throw XCTSkip("WebKit was still compiling the ruleset after 120 s") }
        XCTAssertTrue(
            title?.hasSuffix("Failed to apply rules.") == true,
            "WebKit now turns off every ruleset during its first compile (\(title ?? "nil")): drop the wait of updateEnabledRulesets (dnr-rules.ts)"
        )
    }

    func testStorageSetMiscountsAValueOutsideLatin1() async throws {
        let title = try await bareWorkerTitle("""
        (async () => {
          await chrome.storage.local.set({ key: String.fromCharCode(0x2019).repeat(1000) });
          await chrome.storage.local.set({ key: 'x' });
        })().then(() => 'stored', (error) => error.message).then((title) => chrome.action.setTitle({ title }));
        """, permissions: ["storage"])
        XCTAssertTrue(
            title?.contains("quota") == true,
            "WebKit now sizes a replaced value as it sizes the stored total (\(title ?? "nil")): drop storageAreaPatches (storage-area.ts)"
        )
    }

    func testEventListenerMethodsThrowOnANonFunction() async throws {
        let title = try await bareWorkerTitle("""
        const removeListener = Object.getPrototypeOf(chrome.storage.onChanged).removeListener;
        try {
          (removeListener.__liloUnwrapped ?? removeListener).call(chrome.storage.onChanged, undefined);
          chrome.action.setTitle({ title: 'ignored' });
        } catch {
          chrome.action.setTitle({ title: 'thrown' });
        }
        """, permissions: ["storage"])
        XCTAssertEqual(title, "thrown", "WebKit now ignores a listener that is not a function: drop that check from chromeEvent (chrome-leniency.ts)")
    }

    func testEventsSkipAContextWhoseBrowserAndChromeAreReplaced() async throws {
        let title = try await bareWorkerTitle("""
        const { action, storage } = chrome;
        storage.onChanged.addListener(() => action.setTitle({ title: 'event' }));
        globalThis.browser = {};
        globalThis.chrome = {};
        storage.local.set({ key: 1 });
        setTimeout(() => action.setTitle({ title: 'no event' }), 1000);
        """, permissions: ["storage"])
        XCTAssertEqual(title, "no event", "WebKit now finds a context's listeners without its browser or chrome object: the browser accessor of installChromeCompat (chrome-compat.ts) may go")
    }

    func testPortMessagesSentBeforeTheConnectionArriveTwice() async throws {
        let result = try await barePageResult(worker: """
        let received = 0;
        chrome.runtime.onConnect.addListener((port) => port.onMessage.addListener(() => { received++; }));
        chrome.runtime.onMessage.addListener((message, sender, reply) => { reply(String(received)); });
        """, pageScript: """
        chrome.runtime.connect().postMessage('once');
        await new Promise((resolve) => setTimeout(resolve, 500));
        return await chrome.runtime.sendMessage('count');
        """)
        XCTAssertEqual(result, "2", "WebKit now delivers a message sent before its port connects once, as Chrome: drop messagesOnce and the onConnect stand-in (runtime.ts)")
    }

    func testExtensionPagesAreNotClientsOfTheWorker() async throws {
        let result = try await barePageResult(worker: """
        let messages = 0;
        self.addEventListener('message', () => { messages++; });
        chrome.runtime.onMessage.addListener((message, sender, reply) => {
          clients.matchAll({ includeUncontrolled: true }).then((all) => reply(`${registration.scope === chrome.runtime.getURL('')} ${all.length} ${messages}`));
          return true;
        });
        """, workerPath: "worker/background.js", pageScript: """
        let worker;
        while (!(worker = (await navigator.serviceWorker.getRegistrations())[0]?.active)) await new Promise((resolve) => setTimeout(resolve, 50));
        worker.postMessage('hello');
        await new Promise((resolve) => setTimeout(resolve, 500));
        return await chrome.runtime.sendMessage('state');
        """)
        XCTAssertEqual(result, "false 0 0", "WebKit now scopes the worker to the extension root and counts its pages as clients, as Chrome: drop worker-messages.ts")
    }

    func testExtensionPagesAreScriptedAndFollowedAsWebPages() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()
        let folder = try writeExtension([
            "manifest_version": 3, "name": "Pages", "version": "1.0", "permissions": ["scripting", "tabs", "webNavigation"],
            "host_permissions": ["<all_urls>"], "background": ["service_worker": "background.js"]
        ], files: ["page.html": "<p>page</p>", "background.js": """
        const event = chrome.webNavigation.onDOMContentLoaded;
        Object.getPrototypeOf(event).addListener.__liloUnwrapped.call(event, (details) => { self.loaded ||= details.url.endsWith('/page.html'); });
        chrome.runtime.onMessage.addListener((message, sender, reply) => { reply(self.loaded ? 'loaded' : 'not followed'); });
        """])
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        _ = await registry.backgrounds.load(id)
        let tab = try XCTUnwrap(window.createTabStateFirst(url: context.baseURL.appendingPathComponent("page.html")))
        var page: WKWebView?
        await pollUntil {
            page = window.tabManager.engineTab(for: tab.id)?.view as? WKWebView
            return (try? await page?.evaluateJavaScript("document.readyState + location.pathname")) as? String == "complete/page.html"
        }
        let result = try await XCTUnwrap(page).callAsyncJavaScript("""
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        const executeScript = chrome.scripting.executeScript.__liloUnwrapped ?? chrome.scripting.executeScript;
        const scripted = await executeScript.call(chrome.scripting, { target: { tabId: tab.id }, func: () => 'ran' }).then((results) => results[0].result, (error) => error.message);
        return `${scripted} ${await chrome.runtime.sendMessage('loaded?')}`;
        """, arguments: [:], in: nil, contentWorld: .page) as? String
        let parts = result?.components(separatedBy: " ") ?? []
        XCTAssertEqual(parts.first, "ran", "WebKit now refuses to script the extension's own pages, as Chrome: drop ownPagesRefused (chrome-leniency.ts)")
        XCTAssertEqual(parts.last, "loaded", "WebKit now stops following an extension page at its commit, as Chrome: drop skippingExtensionPages (augmentation/webNavigation.ts)")
    }

    func testMenusUpdateRefusesTheCurrentParent() async throws {
        let title = try await bareWorkerTitle("""
        chrome.contextMenus.create({ id: 'parent', title: 'Parent' });
        chrome.contextMenus.create({ id: 'child', title: 'Child', parentId: 'parent' });
        chrome.contextMenus.update('child', { parentId: 'parent' }).then(() => 'updated', (error) => error.message).then((title) => chrome.action.setTitle({ title }));
        """, permissions: ["contextMenus"])
        XCTAssertTrue(
            title?.contains("cannot be itself or another ancestor") == true,
            "WebKit now takes the current parent in menus.update (\(title ?? "nil")): drop the parentId retry of contextMenusPatches.update (chrome-leniency.ts)"
        )
    }

    func testExecuteScriptInjectsIntoALoadingDocumentAtOnce() async throws {
        // The page stays loading while its script is held back.
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET /slow ") {
                Thread.sleep(forTimeInterval: 3)
                return ("200 OK", ["Content-Type: text/javascript"], Data())
            }
            return ("200 OK", ["Content-Type: text/html"], Data(#"<p>start</p><script src="/slow"></script><p>end</p>"#.utf8))
        }
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()
        let folder = try writeExtension([
            "manifest_version": 3, "name": "Inject", "version": "1.0", "action": [String: Any](), "permissions": ["scripting"],
            "host_permissions": ["<all_urls>"], "background": ["service_worker": "background.js"],
            "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_start"]]
        ], files: ["content.js": "chrome.runtime.sendMessage('started');", "background.js": """
        chrome.runtime.onMessage.addListener((message, sender) => {
          const execute = chrome.scripting.executeScript.__liloUnwrapped ?? chrome.scripting.executeScript;
          execute.call(chrome.scripting, { target: { tabId: sender.tab.id }, func: () => document.readyState })
            .then(([injection]) => chrome.action.setTitle({ title: injection.result }));
        });
        """])
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        _ = await registry.backgrounds.load(id)
        _ = window.createTabStateFirst(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))
        await pollUntil(timeout: 10) { context.action(for: nil)?.label != "Inject" }

        XCTAssertEqual(
            context.action(for: nil)?.label, "loading",
            "WebKit now waits for the document to load unless injectImmediately: drop the executeScript patch (chrome-leniency.ts)"
        )
    }

    func testDeclarativeNetRequestRejectsResourceTypesChromeKnows() async throws {
        let title = try await bareWorkerTitle("""
        (async () => {
          const rejected = [];
          let id = 1;
          for (const type of ['object', 'csp_report', 'webtransport', 'webbundle']) {
            const rule = { id: id, action: { type: 'block' }, condition: { urlFilter: `lilo${id}`, resourceTypes: [type] } };
            id += 1;
            try { await chrome.declarativeNetRequest.updateSessionRules({ addRules: [rule] }); } catch { rejected.push(type); }
          }
          return rejected.join(' ');
        })().then((title) => chrome.action.setTitle({ title }));
        """, permissions: ["declarativeNetRequest"])
        XCTAssertEqual(title, "object csp_report webtransport webbundle", "WebKit now takes these resource types: drop NON_WEBKIT_TYPES (dnr-rules.ts)")
    }

    func testDeclarativeNetRequestRejectsEmptyExclusions() async throws {
        let title = try await bareWorkerTitle("""
        (async () => {
          const rejected = [];
          for (const key of ['excludedInitiatorDomains', 'excludedDomains', 'excludedRequestMethods']) {
            const rule = { id: 1, action: { type: 'block' }, condition: { urlFilter: 'lilo', [key]: [] } };
            try { await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [1], addRules: [rule] }); } catch { rejected.push(key); }
          }
          return rejected.join(' ');
        })().then((title) => chrome.action.setTitle({ title }));
        """, permissions: ["declarativeNetRequest"])
        XCTAssertEqual(
            title, "excludedInitiatorDomains excludedDomains excludedRequestMethods",
            "WebKit now takes empty exclusion lists: drop EXCLUSIONS (dnr-rules.ts)"
        )
    }

    func testWorkerPortToAPageInAnotherProcessDisconnects() async throws {
        let folder = try writeExtension([
            "manifest_version": 3, "name": "Gap", "version": "1.0", "action": ["default_title": "waiting"],
            "background": ["service_worker": "background.js"]
        ], files: [
            "background.js": """
            browser.runtime.onConnect.addListener(() => {});
            browser.runtime.onMessage.addListener(() => {
              const port = browser.runtime.connect();
              const kept = setTimeout(() => browser.action.setTitle({ title: 'connected' }), 5000);
              port.onDisconnect.addListener(() => { clearTimeout(kept); browser.action.setTitle({ title: 'disconnected' }); });
            });
            """,
            "page.html": "<script src=page.js></script>",
            // Busy past the connection, so the worker's own process answers first, as it nearly always does.
            "page.js": """
            browser.runtime.onConnect.addListener((port) => { globalThis.port = port; });
            browser.runtime.sendMessage('connect back');
            for (const end = Date.now() + 2000; Date.now() < end;) {}
            """
        ])
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        await withCheckedContinuation { continuation in context.loadBackgroundContent { _ in continuation.resume() } }
        // WebKit relates its extension pages to the background, so they share its process: this one does not.
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        configuration.setValue(nil, forKey: "relatedWebView")
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        await pollUntil(timeout: 30) { context.action(for: nil)?.label != "waiting" }
        let background = context.value(forKey: "_backgroundWebView") as? WKWebView
        XCTAssertNotEqual(page.value(forKey: "_webProcessIdentifier") as? Int, background?.value(forKey: "_webProcessIdentifier") as? Int)

        XCTAssertEqual(
            context.action(for: nil)?.label, "disconnected",
            "WebKit now waits for every process before it disconnects a port nobody received yet: Postman Interceptor can leave the intermittent list"
        )
    }
}

/// Refuses every native host, as an app without it does.
private final class RefusingNativeHosts: NSObject, WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(NSError(domain: "Lilo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Specified native messaging host not found."]))
    }
}
