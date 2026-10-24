import GRDB
import WebKit
import XCTest
@testable import Lilo

/// chrome.userScripts end to end: gap calls through the router, the "Allow user scripts" switch, the
/// scripts the profile's tabs receive, and registrations surviving a rebuilt profile context.
@MainActor
final class UserScriptsBridgeHandlerTests: XCTestCase {
    private var tempDir: URL!
    private var factory: WKEngineFactory!
    private var cache: ProfileContextCache!
    private var profileId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        profileId = TestProfileIds.next()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("user-scripts-\(UUID().uuidString)")
        let dbManager = try DatabaseManager(appSupportDirectory: tempDir.path)
        try insertTestProfile(profileId, into: dbManager.globalPool)
        let factory = WKEngineFactory()
        factory.suppressWarmPool = true
        self.factory = factory
        cache = ProfileContextCache { profileId in
            let context = try ProfileContext(profileId: profileId, dbManager: dbManager, gapRouter: factory.gapRouter)
            factory.prepareExtensionRegistry(context.extensions)
            return context
        }
        factory.profileContexts = cache
        cache.pinnedProfileIds = [profileId]
    }

    override func tearDown() {
        cache = nil
        factory = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func loadExtension(into registry: ProfileExtensionRegistry) async throws -> String {
        let dir = tempDir.appendingPathComponent("ext", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Scripts", "version": "1.0",
            "permissions": ["userScripts"], "host_permissions": ["*://example.com/*"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "window.fromFile = 1;".write(to: dir.appendingPathComponent("file.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: dir)
        return try XCTUnwrap(registry.loadedExtensions.first?.id)
    }

    private func call(_ method: String, _ params: [String: Any], as extensionId: String, in registry: ProfileExtensionRegistry) async throws -> (Any?, String?) {
        let router = factory.gapRouter
        return await router.route(
            namespace: "userScripts", method: method, params: params,
            extensionId: extensionId, fromWorker: true, registry: registry
        )
    }

    private func tabScripts() -> [WKUserScript] {
        let store = factory.createDataStore(persistent: true, identifier: profileId.uuidString)
        return factory.createTab(configuration: .init(dataStore: store, profileId: profileId)).wkWebView.configuration.userContentController.userScripts
    }

    private let script: [String: Any] = [
        "id": "greeter", "matches": ["*://*/*"], "js": [["code": "window.liloUserScriptMarker = 1;"], ["file": "file.js"]],
        "runAt": "document_start", "includeGlobs": ["*example.com/*"]
    ]

    func testOnlyTheExternallyConnectablePagesOfALoadedExtensionGetChromeRuntime() async throws {
        let registry = try cache.context(for: profileId).extensions
        func connectable() -> [WKUserScript] {
            tabScripts().filter { $0.source == ExtensionUserScripts.externallyConnectableRuntimeSource }
        }
        XCTAssertEqual(connectable().count, 0, "no extension names a page")

        let dir = tempDir.appendingPathComponent("connectable", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Connectable", "version": "1.0",
            "externally_connectable": ["matches": ["https://app.example.org/*"]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try await registry.load(from: dir)
        XCTAssertEqual(connectable().count, 1)
        XCTAssertFalse(try XCTUnwrap(connectable().first).isForMainFrameOnly)

        await registry.unload(extensionId: try XCTUnwrap(registry.loadedExtensions.first?.id))
        XCTAssertEqual(connectable().count, 0)
    }

    func testCallsFailUntilTheUserAllowsUserScripts() async throws {
        let registry = try cache.context(for: profileId).extensions
        let extensionId = try await loadExtension(into: registry)

        let (_, error) = try await call("register", ["scripts": [script]], as: extensionId, in: registry)

        XCTAssertNotNil(error, "the API stays off until Allow user scripts is on")
        XCTAssertFalse(tabScripts().contains { $0.source.contains("liloUserScriptMarker") })
    }

    func testRegisteredScriptReachesTheProfileTabsAndSurvivesARebuild() async throws {
        let registry = try cache.context(for: profileId).extensions
        let extensionId = try await loadExtension(into: registry)
        await registry.setUserScriptsAllowed(extensionId: extensionId, allowed: true)

        let (_, error) = try await call("register", ["scripts": [script]], as: extensionId, in: registry)
        XCTAssertNil(error)
        let (_, duplicate) = try await call("register", ["scripts": [script]], as: extensionId, in: registry)
        XCTAssertEqual(duplicate, "Duplicate script ID 'greeter'")

        let injected = try XCTUnwrap(tabScripts().first { $0.source.contains("liloUserScriptMarker") })
        XCTAssertTrue(injected.source.contains("window.fromFile = 1;"), "file sources are read from the extension")
        XCTAssertTrue(injected.source.hasPrefix("if ("), "globs guard the code")
        XCTAssertEqual(injected.injectionTime, .atDocumentStart)
        XCTAssertTrue(injected.isForMainFrameOnly)

        // Evicting the profile tears its registry down and takes the scripts out of open tabs.
        let controller = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: true, identifier: profileId.uuidString), profileId: profileId))
            .wkWebView.configuration.userContentController
        cache.removeContext(for: profileId)
        XCTAssertFalse(controller.userScripts.contains { $0.source.contains("liloUserScriptMarker") })

        let rebuilt = try cache.context(for: profileId).extensions
        await rebuilt.restore()
        XCTAssertTrue(controller.userScripts.contains { $0.source.contains("liloUserScriptMarker") }, "a restore reinstalls persisted scripts")
        let (scripts, _) = try await call("getScripts", [:], as: extensionId, in: rebuilt)
        XCTAssertEqual((scripts as? [[String: Any]])?.first?["id"] as? String, "greeter")

        let (_, unregisterError) = try await call("unregister", ["filter": ["ids": ["greeter"]]], as: extensionId, in: rebuilt)
        XCTAssertNil(unregisterError)
        XCTAssertFalse(controller.userScripts.contains { $0.source.contains("liloUserScriptMarker") })
    }

    func testRegisteringAnotherScriptKeepsTheInstalledOnes() async throws {
        let registry = try cache.context(for: profileId).extensions
        let extensionId = try await loadExtension(into: registry)
        await registry.setUserScriptsAllowed(extensionId: extensionId, allowed: true)
        let controller = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: true, identifier: profileId.uuidString), profileId: profileId))
            .wkWebView.configuration.userContentController

        _ = try await call("register", ["scripts": [script]], as: extensionId, in: registry)
        let first = try XCTUnwrap(controller.userScripts.first { $0.source.contains("liloUserScriptMarker") })
        let second: [String: Any] = ["id": "second", "matches": ["*://*/*"], "js": [["code": "window.liloSecondMarker = 1;"]]]
        _ = try await call("register", ["scripts": [second]], as: extensionId, in: registry)

        XCTAssertEqual(controller.userScripts.filter { $0.source.contains("liloUserScriptMarker") }.count, 1)
        XCTAssertTrue(controller.userScripts.contains { $0 === first }, "an unchanged script is neither rebuilt nor reinstalled")
        XCTAssertTrue(controller.userScripts.contains { $0.source.contains("liloSecondMarker") })
    }

    func testTheWorkerPreludeCarriesTheUserScriptsSwitch() async throws {
        let registry = try cache.context(for: profileId).extensions
        let dir = tempDir.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Worker","version":"1.0","permissions":["userScripts"],"background":{"service_worker":"sw.js"}}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: dir)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let prelude = URL(fileURLWithPath: try XCTUnwrap(registry.loadedExtensions.first?.sourcePath)).appendingPathComponent("lilo-background-prelude.js")
        XCTAssertTrue(try String(contentsOf: prelude, encoding: .utf8).contains("globalThis.__liloUserScriptsAllowed = false;"))

        await registry.setUserScriptsAllowed(extensionId: extensionId, allowed: true)

        XCTAssertTrue(try String(contentsOf: prelude, encoding: .utf8).contains("globalThis.__liloUserScriptsAllowed = true;"))
    }

    func testMessagingWorldGetsTheSendMessageShim() async throws {
        let registry = try cache.context(for: profileId).extensions
        let extensionId = try await loadExtension(into: registry)
        await registry.setUserScriptsAllowed(extensionId: extensionId, allowed: true)

        _ = try await call("configureWorld", ["properties": ["messaging": true]], as: extensionId, in: registry)
        _ = try await call("register", ["scripts": [script]], as: extensionId, in: registry)
        let (worlds, _) = try await call("getWorldConfigurations", [:], as: extensionId, in: registry)

        XCTAssertEqual((worlds as? [[String: Any]])?.first?["messaging"] as? Bool, true)
        let injected = try XCTUnwrap(tabScripts().first { $0.source.contains("liloUserScriptMarker") })
        XCTAssertTrue(injected.source.contains("messageHandlers.\(UserScriptsBridgeHandler.messageHandlerName)"))
    }
}

/// chrome.userScripts.execute and runtime.connect ports, in a real window's tab.
@MainActor
final class UserScriptsExecuteTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("user-scripts-execute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A window whose tab shows an https://example.com page, and an extension allowed to script it.
    private func scriptedPage(_ html: String = "<title>Page</title>") async throws -> (registry: ProfileExtensionRegistry, extensionId: String, page: WKWebView) {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let registry = try context.profileContexts.context(for: profileId).extensions
        let dir = tempDir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Scripts", "version": "1.0",
            "permissions": ["userScripts"], "host_permissions": ["*://example.com/*"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try await registry.load(from: dir)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        await registry.setUserScriptsAllowed(extensionId: extensionId, allowed: true)

        let window = makeTestWindow(context, showing: space.id)
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let page = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)?.view as? WKWebView)
        page.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        let loaded = await pollUntil { page.title == "Page" }
        XCTAssertTrue(loaded)
        return (registry, extensionId, page)
    }

    private func call(_ method: String, _ params: [String: Any], as extensionId: String, in registry: ProfileExtensionRegistry) async throws -> (Any?, String?) {
        let router = browserContext.context.engineFactory.gapRouter
        return await router.route(namespace: "userScripts", method: method, params: params, extensionId: extensionId, fromWorker: true, registry: registry)
    }

    func testExecuteRunsInTheTabAndReturnsTheResult() async throws {
        let (registry, extensionId, page) = try await scriptedPage()
        let position = try XCTUnwrap(registry.tabPosition(of: page, extensionId: extensionId))
        let injection: [String: Any] = ["target": ["tabId": 1], "js": [["code": "document.title + ' ' + (6 * 7)"]]]

        let (result, error) = try await call("execute", ["injection": injection, "tabs": [position]], as: extensionId, in: registry)
        let (_, mainWithWorldId) = try await call(
            "execute", ["injection": injection.merging(["world": "MAIN", "worldId": "w"]) { $1 }, "tabs": [position]], as: extensionId, in: registry
        )

        XCTAssertNil(error)
        XCTAssertEqual((result as? [[String: Any]])?.first?["result"] as? String, "Page 42")
        XCTAssertNotNil(mainWithWorldId, "a worldId has no meaning in the MAIN world")
    }

    func testAUserScriptPortRelaysMessagesBothWays() async throws {
        let (registry, extensionId, page) = try await scriptedPage()
        let position = try XCTUnwrap(registry.tabPosition(of: page, extensionId: extensionId))
        _ = try await call("configureWorld", ["properties": ["messaging": true]], as: extensionId, in: registry)
        let connect = """
            const port = chrome.runtime.connect({ name: "chat" });
            port.onMessage.addListener((message) => { window.fromExtension = message; });
            port.postMessage("hello");
            port.name
            """

        let (result, error) = try await call(
            "execute", ["injection": ["target": ["tabId": 1], "js": [["code": connect]]], "tabs": [position]], as: extensionId, in: registry
        )
        XCTAssertNil(error)
        XCTAssertEqual((result as? [[String: Any]])?.first?["result"] as? String, "chat")

        var events: [GapEventEnvelope] = []
        let delivered = await pollUntil {
            events = registry.gapEvents.undelivered(to: extensionId).filter { $0.event == "onUserScriptConnect" }
            return events.count == 2
        }
        XCTAssertTrue(delivered, "the extension hears the connect, then the port's message")
        XCTAssertEqual(events.map { $0.args.first as? String }, ["connect", "message"])
        XCTAssertEqual(events.first?.args[2] as? String, "chat")
        XCTAssertEqual(events.last?.args[2] as? String, "hello")
        let portId = try XCTUnwrap(events.first?.args[1] as? String)

        _ = try await call("portPost", ["portId": portId, "message": ["reply": 1]], as: extensionId, in: registry)

        let world = WKContentWorld.world(name: ExtensionUserScripts.worldName(extensionId: extensionId, worldId: nil))
        let reply = try await page.evaluateJavaScript("window.fromExtension?.reply ?? null", in: nil, contentWorld: world)
        XCTAssertEqual(reply as? Int, 1, "the extension's port message reaches the user script")
    }

    func testExecuteReachesTheFramesAskedForAndAwaitsPromises() async throws {
        let html = #"<meta http-equiv="Content-Security-Policy" content="script-src 'self'"><title>Page</title><iframe srcdoc="<title>Child</title>"></iframe>"#
        let (registry, extensionId, page) = try await scriptedPage(html)
        let childLoaded = await pollUntil {
            (try? await page.evaluateJavaScript("frames[0]?.document?.title ?? ''") as? String) == "Child"
        }
        XCTAssertTrue(childLoaded)
        let position = try XCTUnwrap(registry.tabPosition(of: page, extensionId: extensionId))
        func execute(_ code: String, _ target: [String: Any], world: String? = nil) async throws -> [[String: Any]] {
            var injection: [String: Any] = ["target": target.merging(["tabId": 1]) { $1 }, "js": [["code": code]]]
            injection["world"] = world
            let (result, error) = try await call("execute", ["injection": injection, "tabs": [position]], as: extensionId, in: registry)
            XCTAssertNil(error)
            return result as? [[String: Any]] ?? []
        }

        let everywhere = try await execute("Promise.resolve(document.title)", ["allFrames": true])
        XCTAssertEqual(everywhere.compactMap { $0["result"] as? String }.sorted(), ["Child", "Page"], "every frame answers, its promise awaited")
        XCTAssertEqual(everywhere.first { $0["result"] as? String == "Page" }?["frameId"] as? Int, 0)
        let childId = try XCTUnwrap(everywhere.first { $0["result"] as? String == "Child" }?["frameId"] as? Int)
        XCTAssertNotEqual(childId, 0)

        let childOnly = try await execute("document.title", ["frameIds": [childId]])
        XCTAssertEqual(childOnly.map { $0["result"] as? String }, ["Child"])

        // The page's CSP refuses eval in its own world: the script still runs, unawaited.
        let main = try await execute("window.ranInMain = true; 1 + 1", [:], world: "MAIN")
        XCTAssertEqual(main.first?["result"] as? Int, 2)
    }

    func testAnExtensionPageDetectsTheUserScriptsSwitchAtOnce() async throws {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "Q").id
        let space = try context.spaceManager.createSpace(name: "T", profileId: profileId)
        let registry = try context.profileContexts.context(for: profileId).extensions
        let dir = tempDir.appendingPathComponent("page-detects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Detects","version":"1.0","permissions":["userScripts"]}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<title>Detect</title>".write(to: dir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try await registry.load(from: dir)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let window = makeTestWindow(context, showing: space.id)
        func detect() async throws -> String? {
            let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "chrome-extension://\(extensionId)/page.html")))
            let page = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)?.view as? WKWebView)
            _ = await pollUntil { page.title == "Detect" }
            return try await page.evaluateJavaScript("(() => { try { chrome.userScripts.getScripts(); return 'available'; } catch { return 'off'; } })()") as? String
        }

        let before = try await detect()
        await registry.setUserScriptsAllowed(extensionId: extensionId, allowed: true)
        let after = try await detect()

        XCTAssertEqual(before, "off")
        XCTAssertEqual(after, "available")
    }
}
