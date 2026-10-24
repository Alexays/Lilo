import GRDB
import WebKit
import XCTest
@testable import Lilo

/// Chrome APIs Lilo fills in where WebKit has none: offscreen, search, i18n.detectLanguage, the
/// persisted side panel behavior, and the namespaces the background prelude adds to a worker.
@MainActor
final class ChromeAPIShimTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeExtension(_ files: [String: String]) throws -> URL {
        let url = tempDir.appendingPathComponent("ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return url
    }

    private func message(_ action: String, _ payload: [String: Any] = [:]) -> BridgeMessage {
        BridgeMessage(dictionary: ["action": action, "payload": payload])!
    }

    func testDetectLanguageRecognizesEnglish() async throws {
        let result = await I18nBridgeHandler().handle(message("i18n.detectLanguage", ["text": "The quick brown fox jumps over the lazy dog every single morning."])
        ) as? [String: Any]
        let first = try XCTUnwrap((result?["languages"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["language"] as? String, "en")
        XCTAssertGreaterThan(first["percentage"] as? Int ?? 0, 50)
    }

    func testSearchURLFallsBackToGoogleAndEncodesLikeTheOmnibox() async {
        let handler = SearchQueryBridgeHandler()
        let url = await handler.handle(message("search.url", ["text": "a b&c"])) as? String
        XCTAssertEqual(url, "https://www.google.com/search?q=a%20b%26c")
    }

    func testSidePanelBehaviorPersistsAcrossHandlers() async throws {
        let registry = try makeTestExtensionRegistry(in: tempDir)
        let extensionId = "side-panel-test"
        defer { UserDefaults.lilo.removeObject(forKey: "sidePanel.\(registry.profileId).\(extensionId)") }

        let writer = SidePanelBridgeHandler()
        _ = await writer.handle(message("sidePanel.setPanelBehavior", ["extensionId": extensionId, "openPanelOnActionClick": true]), registry: registry)

        let reader = SidePanelBridgeHandler()
        let behavior = await reader.handle(message("sidePanel.getPanelBehavior", ["extensionId": extensionId]), registry: registry) as? [String: Any]
        XCTAssertEqual(behavior?["openPanelOnActionClick"] as? Bool, true)
    }

    func testSidePanelSettingsAreRemovedOnUninstallOnly() async throws {
        let registry = try makeTestExtensionRegistry(in: tempDir)
        try await registry.load(from: try writeExtension([
            "manifest.json": #"{"manifest_version": 3, "name": "Panel", "version": "1.0", "permissions": ["sidePanel"]}"#
        ]))
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let key = "sidePanel.\(registry.profileId).\(extensionId)"
        defer { UserDefaults.lilo.removeObject(forKey: key) }
        let handler = SidePanelBridgeHandler()
        _ = await handler.handle(message("sidePanel.setPanelBehavior", ["extensionId": extensionId, "openPanelOnActionClick": true]), registry: registry)

        await registry.disable(extensionId: extensionId)
        XCTAssertNotNil(UserDefaults.lilo.dictionary(forKey: key), "a disable keeps the settings")
        try await registry.enable(extensionId: extensionId)
        await registry.unload(extensionId: extensionId)
        XCTAssertNil(UserDefaults.lilo.dictionary(forKey: key), "an uninstall removes them")
    }

    func testOffscreenDocumentLifecycle() async throws {
        let registry = try makeTestExtensionRegistry(in: tempDir)
        let url = try writeExtension([
            "manifest.json": #"{"manifest_version": 3, "name": "Offscreen", "version": "1.0", "permissions": ["offscreen"]}"#,
            "offscreen.html": "<!doctype html><title>offscreen</title>"
        ])
        try await registry.load(from: url)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let handler = OffscreenBridgeHandler()
        let payload: [String: Any] = ["extensionId": extensionId, "url": "offscreen.html"]

        let created = await handler.handle(message("offscreen.createDocument", payload), registry: registry)
        XCTAssertNil(created as? BridgeError)
        let documentURL = await handler.handle(message("offscreen.documentUrl", payload), registry: registry) as? String
        XCTAssertTrue(documentURL?.hasSuffix("/offscreen.html") == true)
        let second = await handler.handle(message("offscreen.createDocument", payload), registry: registry)
        XCTAssertNotNil(second as? BridgeError)

        _ = await handler.handle(message("offscreen.closeDocument", payload), registry: registry)
        let afterClose = await handler.handle(message("offscreen.documentUrl", payload), registry: registry)
        XCTAssertNil(afterClose)
    }

    /// Loads a prelude-wrapped worker in a bare controller and reads back what the worker sees.
    func testServiceWorkerExposesLiloAddedNamespaces() async throws {
        let url = try writeExtension([
            "manifest.json": """
            {"manifest_version": 3, "name": "Surface", "version": "1.0", "background": {"service_worker": "sw.js"},
             "action": {}, "permissions": ["nativeMessaging", "webNavigation", "privacy", "offscreen", "search", "declarativeNetRequest", "cookies"]}
            """,
            "sw.js": """
            const c = globalThis.chrome;
            c.cookies.getAllCookieStores().then((stores) => stores.length, (e) => String(e)).then((cookieStores) => c.runtime.sendNativeMessage('lilo.test', {
              privacy: typeof c.privacy?.services?.passwordSavingEnabled?.get,
              offscreen: typeof c.offscreen?.createDocument,
              search: typeof c.search?.query,
              getContexts: typeof c.runtime?.getContexts,
              platformOs: c.runtime?.PlatformOs?.MAC ?? null,
              dynamicRuleset: c.declarativeNetRequest?.DYNAMIC_RULESET_ID ?? null,
              badgeTextColor: typeof c.action?.setBadgeTextColor,
              historyStateUpdated: typeof c.webNavigation?.onHistoryStateUpdated?.addListener,
              browserHistoryStateUpdated: typeof globalThis.browser?.webNavigation?.onHistoryStateUpdated?.addListener,
              cookiesChangedShared: c.cookies?.onChanged === globalThis.browser?.cookies?.onChanged,
              cookiesGet: typeof c.cookies?.get,
              cookieStores,
            }));
            """
        ])
        XCTAssertFalse(ProfileExtensionRegistry.prepareForWebKit(at: url, allowsUserScripts: false), "prelude preparation degraded")

        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let receiver = NativeMessageReceiver()
        let reported = expectation(description: "worker reported its surface")
        receiver.received = reported
        controller.delegate = receiver
        let context = WKWebExtensionContext(for: webExtension)
        webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        try await context.loadBackgroundContent()
        await fulfillment(of: [reported], timeout: 5)

        let surface = try XCTUnwrap(receiver.message as? [String: Any])
        XCTAssertEqual(surface["privacy"] as? String, "function")
        XCTAssertEqual(surface["offscreen"] as? String, "function")
        XCTAssertEqual(surface["search"] as? String, "function")
        XCTAssertEqual(surface["getContexts"] as? String, "function")
        XCTAssertEqual(surface["platformOs"] as? String, "mac")
        XCTAssertEqual(surface["dynamicRuleset"] as? String, "_dynamic")
        XCTAssertEqual(surface["badgeTextColor"] as? String, "function")
        XCTAssertEqual(surface["historyStateUpdated"] as? String, "function")
        XCTAssertEqual(surface["browserHistoryStateUpdated"] as? String, "function", "webextension-polyfill hands extensions WebKit's browser")
        XCTAssertEqual(surface["cookiesChangedShared"] as? Bool, true, "browser.cookies.onChanged is chrome's, as in Chrome: Lilo's event takes its listeners")
        XCTAssertEqual(surface["cookiesGet"] as? String, "function")
        XCTAssertEqual(surface["cookieStores"] as? Int, 1, "WebKit's methods still run through the cookies view")
        try controller.unload(context)
    }

    /// A worker WebKit would run as a background page (`scripts` kept for Firefox), seen at its own
    /// URL, whose declarativeNetRequest rules Chrome accepts and WebKit compiles differently.
    func testPreparedWorkerRunsAsInChromeAndAcceptsChromeRules() async throws {
        let url = try writeExtension([
            "manifest.json": """
            {"manifest_version": 3, "name": "Rules", "version": "1.0", "background": {"service_worker": "BG.js", "scripts": ["BG.js"]},
             "permissions": ["nativeMessaging", "declarativeNetRequest", "storage"], "host_permissions": ["<all_urls>"]}
            """,
            "BG.js": """
            const dnr = chrome.declarativeNetRequest;
            const rules = [
              { id: 1, action: { type: 'block' }, condition: { regexFilter: '.*/trace/mail/.*u=42($|&)', resourceTypes: ['image'] } },
              { id: 2, action: { type: 'redirect', redirect: { regexSubstitution: '\\\\1' } }, condition: { regexFilter: '.*(?:meips|proxy).*#(.*)' } },
              { id: 3, action: { type: 'redirect', redirect: { url: 'data:,?data=1' } }, condition: { urlFilter: '|https://*.roblox.com/?btr_settings|' } },
              { id: 4, action: { type: 'redirect', redirect: { url: chrome.runtime.getURL('/BG.js?x=1') } }, condition: { urlFilter: 'ads.example' } },
              { id: 5, action: { type: 'modifyHeaders', requestHeaders: [{ header: 'X-Kopernio-Plugin-Version', operation: 'set', value: '3' }] }, condition: { urlFilter: 'kopernio' } },
            ];
            (async () => {
              const { getManifest } = chrome.runtime;
              const report = {
                worker: typeof ServiceWorkerGlobalScope, href: location.href, location: location.constructor.name,
                brand: navigator.userAgentData?.brands[0].brand, detached: getManifest()?.name,
                storageMembers: Object.keys(chrome.storage.local).includes('get'),
              };
              try { await dnr.updateDynamicRules({ addRules: rules }); report.update = 'ok'; } catch (e) { report.update = String(e); }
              const canonical = (value) => JSON.stringify(value, (_, v) => v && typeof v === 'object' && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort()) : v);
              report.roundTrip = canonical(await dnr.getDynamicRules()) === canonical(rules);
              const isRegexSupported = dnr.isRegexSupported;
              report.supported = (await isRegexSupported({ regex: '^https?://([\\\\w-]+[.])?duckduckgo[.]com/[?]x(?:=[^&]*)?$' })).isSupported;
              report.unsupported = (await isRegexSupported({ regex: '(?:meips|proxy)' })).isSupported;
              chrome.runtime.sendNativeMessage('lilo.test', report);
            })();
            """
        ])
        XCTAssertFalse(ProfileExtensionRegistry.prepareForWebKit(at: url, allowsUserScripts: false), "prelude preparation degraded")

        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let receiver = NativeMessageReceiver()
        let reported = expectation(description: "worker reported")
        receiver.received = reported
        controller.delegate = receiver
        let context = WKWebExtensionContext(for: webExtension)
        webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        try await context.loadBackgroundContent()
        await fulfillment(of: [reported], timeout: 5)

        let report = try XCTUnwrap(receiver.message as? [String: Any])
        XCTAssertEqual(report["worker"] as? String, "function", "Chrome runs the service worker, not the Firefox scripts")
        XCTAssertEqual((report["href"] as? String).map { URL(string: $0)?.lastPathComponent }, "BG.js")
        XCTAssertEqual(report["location"] as? String, "WorkerLocation")
        XCTAssertEqual(report["brand"] as? String, "Chromium", "navigator.userAgentData, which WebKit lacks")
        XCTAssertEqual(report["detached"] as? String, "Rules", "a method called detached still has its namespace")
        XCTAssertEqual(report["storageMembers"] as? Bool, true, "API methods are own enumerable members")
        XCTAssertEqual(report["update"] as? String, "ok")
        XCTAssertEqual(report["roundTrip"] as? Bool, true, "getDynamicRules answers the rules the extension added")
        XCTAssertEqual(report["supported"] as? Bool, true)
        XCTAssertEqual(report["unsupported"] as? Bool, false)
        try controller.unload(context)
    }

    /// A background WebKit runs as a page (`scripts` or `page` with no service worker) gets the page augmentation, as the
    /// extension's other pages do, instead of the worker's prelude.
    func testABackgroundPageGetsThePageAugmentation() async throws {
        let report = """
        chrome.action.setTitle({ title: JSON.stringify({
          augmented: globalThis.__liloAugmentationInstalled === true, privacy: typeof chrome.privacy?.services?.passwordSavingEnabled?.get,
        }) });
        """
        let scripts = try writeExtension([
            "manifest.json": #"{"manifest_version": 3, "name": "Scripts", "version": "1.0", "background": {"scripts": ["bg.js"]}, "action": {"default_title": "waiting"}, "permissions": ["privacy"]}"#,
            "bg.js": report
        ])
        let page = try writeExtension([
            "manifest.json": #"{"manifest_version": 3, "name": "Page", "version": "1.0", "background": {"page": "bg.html"}, "action": {"default_title": "waiting"}, "permissions": ["privacy"]}"#,
            "bg.html": "<script src=\"bg.js\"></script>",
            "bg.js": report
        ])
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let augmentation = try String(contentsOf: XCTUnwrap(Bundle.appResourceURL("ChromeAPIAugmentation", extension: "js")), encoding: .utf8)
        configuration.webViewConfiguration.userContentController.addUserScript(
            WKUserScript(source: augmentation, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        )
        let controller = WKWebExtensionController(configuration: configuration)
        for url in [scripts, page] {
            XCTAssertEqual(try ProfileExtensionRegistry.prepareBackgroundServiceWorkerForWKIfNeeded(at: url, allowsUserScripts: false), .notNeeded)
            let webExtension = try await WKWebExtension(resourceBaseURL: url)
            let context = WKWebExtensionContext(for: webExtension)
            webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
            try controller.load(context)
            try await context.loadBackgroundContent()
            await pollUntil(timeout: 5) { context.action(for: nil)?.label != "waiting" }
            XCTAssertEqual(context.action(for: nil)?.label, #"{"augmented":true,"privacy":"function"}"#, url.lastPathComponent)
            try controller.unload(context)
        }
    }

    /// A prepared worker reads back what it has just stored, as in Chrome.
    func testPreparedWorkerReadsWhatItHasJustStored() async throws {
        let url = try writeExtension([
            "manifest.json": """
            {"manifest_version": 3, "name": "Order", "version": "1.0", "background": {"service_worker": "sw.js"},
             "action": {"default_title": "waiting"}, "permissions": ["storage"]}
            """,
            "sw.js": """
            chrome.storage.local.set({ key: 1 });
            chrome.storage.local.get('key', (items) => chrome.action.setTitle({ title: JSON.stringify(items) }));
            """
        ])
        XCTAssertFalse(ProfileExtensionRegistry.prepareForWebKit(at: url, allowsUserScripts: false), "prelude preparation degraded")
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: webExtension)
        webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        try await context.loadBackgroundContent()
        await pollUntil(timeout: 5) { context.action(for: nil)?.label != "waiting" }

        XCTAssertEqual(context.action(for: nil)?.label, #"{"key":1}"#)
        try controller.unload(context)
    }

    /// A prepared worker's callbacks of Lilo's fixes, and of a message no one answers, see Chrome's
    /// error as chrome.runtime.lastError.
    func testPreparedWorkerCallbacksSeeLastError() async throws {
        let url = try writeExtension([
            "manifest.json": """
            {"manifest_version": 3, "name": "Errors", "version": "1.0", "background": {"service_worker": "sw.js"},
             "action": {"default_title": "waiting"}, "permissions": ["contextMenus"]}
            """,
            "sw.js": """
            chrome.contextMenus.create({ id: 'untitled' }, () => {
              const menu = chrome.runtime.lastError?.message;
              chrome.runtime.sendMessage({ ping: 1 }, (response) => {
                chrome.action.setTitle({ title: `${menu} | ${response} ${chrome.runtime.lastError?.message}` });
              });
            });
            """
        ])
        XCTAssertFalse(ProfileExtensionRegistry.prepareForWebKit(at: url, allowsUserScripts: false), "prelude preparation degraded")
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: webExtension)
        webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        try await context.loadBackgroundContent()
        await pollUntil(timeout: 5) { context.action(for: nil)?.label != "waiting" }

        XCTAssertEqual(
            context.action(for: nil)?.label,
            "All menu items except for separators must have a title | undefined Could not establish connection. Receiving end does not exist."
        )
        try controller.unload(context)
    }

    /// A script `executeScript` injects runs the content compat: `tabs.sendMessage` tells its listener from none,
    /// and `insertCSS` reaches the frame named.
    func testScriptedContentScriptsAnswerAsChrome() async throws {
        let server = try await TinyHTTPServer { request in
            let body = request.hasPrefix("GET /frame ") ? "<p>frame</p>" : #"<p>top</p><iframe src="/frame"></iframe>"#
            return ("200 OK", ["Content-Type: text/html"], Data(body.utf8))
        }
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()
        let folder = try writeExtension([
            "manifest.json": """
            {"manifest_version": 3, "name": "Scripted", "version": "1.0", "action": {}, "background": {"service_worker": "sw.js"},
             "permissions": ["scripting", "webNavigation"], "host_permissions": ["<all_urls>"]}
            """,
            "content.js": "chrome.runtime.onMessage.addListener((message, sender, reply) => { if (message === 'ping') reply('pong'); });",
            "sw.js": """
            let ran = false;
            chrome.tabs.onUpdated.addListener(async (tabId, change) => {
              if (change.status !== 'complete' || ran) return;
              ran = true;
              const outcome = (sent) => sent.then((answer) => String(answer), (error) => error.message);
              const results = [await outcome(chrome.tabs.sendMessage(tabId, 'ping'))];
              await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['content.js'] });
              results.push(await outcome(chrome.tabs.sendMessage(tabId, 'ping')), await outcome(chrome.tabs.sendMessage(tabId, 'quiet')));
              results.push(await new Promise((resolve) => chrome.tabs.sendMessage(tabId, 'quiet', () => resolve(chrome.runtime.lastError?.message))));
              const frames = await chrome.webNavigation.getAllFrames({ tabId });
              const child = frames.find((frame) => frame.frameId !== 0).frameId;
              await chrome.scripting.insertCSS({ target: { tabId, frameIds: [child] }, css: 'p { color: rgb(1, 2, 3) }' });
              const colors = await chrome.scripting.executeScript({
                target: { tabId, allFrames: true }, func: () => getComputedStyle(document.querySelector('p')).color,
              });
              results.push(colors.map((color) => `${color.frameId === 0 ? 'top' : 'child'} ${color.result}`).sort().join(', '));
              chrome.action.setTitle({ title: results.join(' | ') });
            });
            """
        ])
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        _ = await registry.backgrounds.load(id)
        _ = window.createTabStateFirst(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))
        await pollUntil(timeout: 15) { context.action(for: nil)?.label != "Scripted" }

        XCTAssertEqual(context.action(for: nil)?.label, [
            "Could not establish connection. Receiving end does not exist.", "pong", "undefined",
            "The message port closed before a response was received.", "child rgb(1, 2, 3), top rgb(0, 0, 0)"
        ].joined(separator: " | "))
    }
}

@MainActor
final class NativeMessageReceiver: NSObject, WKWebExtensionControllerDelegate {
    var received: XCTestExpectation?
    var message: Any?

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        replyHandler(nil, nil)
        // Without a port handler WebKit hands the prelude's channel messages here too.
        guard applicationIdentifier == "lilo.test" else { return }
        self.message = message
        received?.fulfill()
        received = nil
    }
}
