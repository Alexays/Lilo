import WebKit
import XCTest
@testable import Lilo

/// Gap calls reach the profile whose extension controller opened the caller's channel, whichever
/// profile the window displays.
@MainActor
final class GapRouterStoreProviderTests: XCTestCase {
    private var tempDir: URL!
    private var factory: WKEngineFactory!
    private var cache: ProfileContextCache!
    private var profileA: ProfileContext!
    private var profileB: ProfileContext!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("gap-store-\(UUID().uuidString)")
        let dbManager = try DatabaseManager(appSupportDirectory: tempDir.path)
        let factory = WKEngineFactory()
        self.factory = factory
        cache = ProfileContextCache { profileId in
            try ProfileContext(profileId: profileId, dbManager: dbManager, gapRouter: factory.gapRouter)
        }
        factory.profileContexts = cache
        let a = TestProfileIds.next(), b = TestProfileIds.next()
        cache.pinnedProfileIds = [a, b]
        profileA = try cache.context(for: a)
        profileB = try cache.context(for: b)
    }

    override func tearDown() {
        profileA = nil
        profileB = nil
        cache = nil
        factory = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    /// Loads an extension declaring `permissions` into the profile and returns its authenticated id.
    private func loadExtension(
        into profile: ProfileContext,
        permissions: [String] = ["bookmarks", "history", "tabGroups", "sessions"],
        hostPermissions: [String] = []
    ) async throws -> String {
        let dir = tempDir.appendingPathComponent("ext-\(profile.profileId.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Gap", "version": "1.0", "permissions": permissions, "host_permissions": hostPermissions
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try await profile.extensions.load(from: dir)
        return try XCTUnwrap(profile.extensions.loadedExtensions.first?.id)
    }

    func testPageCallReachesItsChannelProfile() async throws {
        let router = factory.gapRouter
        let extensionId = try await loadExtension(into: profileB)
        let (result, error) = await router.route(
            namespace: "bookmarks", method: "create",
            params: ["parentId": "1", "title": "t", "url": "https://b.test"],
            extensionId: extensionId, fromWorker: false, registry: profileB.extensions
        )

        XCTAssertNil(error)
        XCTAssertNotNil(result)
        XCTAssertEqual(try profileB.bookmarks.getChildren(parentId: "1").count, 1)
        XCTAssertEqual(try profileA.bookmarks.getChildren(parentId: "1").count, 0)
    }

    func testWorkerCallReachesItsChannelProfile() async throws {
        let router = factory.gapRouter
        let extensionId = try await loadExtension(into: profileB)
        let (_, error) = await router.route(
            namespace: "history", method: "addUrl",
            params: ["url": "https://b.test/"],
            extensionId: extensionId, fromWorker: true,
            registry: profileB.extensions
        )

        XCTAssertNil(error)
        XCTAssertNotNil(try profileB.history.entry(forURL: "https://b.test/"))
        XCTAssertNil(try profileA.history.entry(forURL: "https://b.test/"))
    }

    /// Tab groups and sessions act on a window of the calling extension's own profile.
    func testWindowScopedGapCallsReceiveTheCallingProfile() async throws {
        var tabGroupsRegistry: ProfileExtensionRegistry?
        var sessionsRegistry: ProfileExtensionRegistry?
        factory.tabGroupsContextProvider = { registry in tabGroupsRegistry = registry; return nil }
        factory.sessionsContextProvider = { registry in sessionsRegistry = registry; return nil }
        let router = factory.gapRouter
        let extensionId = try await loadExtension(into: profileB)

        _ = await router.route(namespace: "tabGroups", method: "query", params: [:], extensionId: extensionId, fromWorker: false, registry: profileB.extensions)
        _ = await router.route(namespace: "sessions", method: "getRecentlyClosed", params: [:], extensionId: extensionId, fromWorker: false, registry: profileB.extensions)

        XCTAssertTrue(tabGroupsRegistry === profileB.extensions)
        XCTAssertTrue(sessionsRegistry === profileB.extensions)
    }

    func testBookmarksTreeIsNestedInIndexOrder() async throws {
        let router = factory.gapRouter
        let extensionId = try await loadExtension(into: profileB)
        _ = try profileB.bookmarks.create(parentId: "1", title: "a", url: "https://a.test")
        _ = try profileB.bookmarks.create(parentId: "1", title: "b", url: "https://b.test")

        let (tree, _) = await router.route(namespace: "bookmarks", method: "getTree", params: [:], extensionId: extensionId, fromWorker: false, registry: profileB.extensions)
        let (subTree, _) = await router.route(namespace: "bookmarks", method: "getSubTree", params: ["id": "1"], extensionId: extensionId, fromWorker: false, registry: profileB.extensions)

        let root = try XCTUnwrap((tree as? [[String: Any]])?.first)
        XCTAssertEqual(root["id"] as? String, "0")
        let folders = try XCTUnwrap(root["children"] as? [[String: Any]])
        XCTAssertEqual(folders.map { $0["id"] as? String }, ["1", "2"])
        XCTAssertEqual((folders[1]["children"] as? [[String: Any]])?.count, 0)
        let bar = try XCTUnwrap((subTree as? [[String: Any]])?.first)
        XCTAssertEqual(bar["id"] as? String, "1")
        let bookmarks = try XCTUnwrap(bar["children"] as? [[String: Any]])
        XCTAssertEqual(bookmarks.map { $0["title"] as? String }, ["a", "b"])
        XCTAssertNil(bookmarks[0]["children"])
    }

    func testHistorySearchDefaultsToTheLastDay() async throws {
        let router = factory.gapRouter
        let extensionId = try await loadExtension(into: profileB)
        try profileB.history.recordVisit(url: "https://b.test/page", title: "Page")

        let (recent, _) = await router.route(namespace: "history", method: "search", params: ["text": ""], extensionId: extensionId, fromWorker: false, registry: profileB.extensions)
        let (matched, _) = await router.route(namespace: "history", method: "search", params: ["text": "page"], extensionId: extensionId, fromWorker: false, registry: profileB.extensions)
        let (old, _) = await router.route(namespace: "history", method: "search", params: ["text": "", "endTime": 1000], extensionId: extensionId, fromWorker: false, registry: profileB.extensions)

        XCTAssertEqual((recent as? [[String: Any]])?.map { $0["url"] as? String }, ["https://b.test/page"])
        XCTAssertEqual((matched as? [[String: Any]])?.count, 1)
        XCTAssertEqual((old as? [[String: Any]])?.count, 0)
    }

    func testCallWithoutTheManifestPermissionIsRejected() async throws {
        let router = factory.gapRouter
        let extensionId = try await loadExtension(into: profileB, permissions: ["bookmarks"])

        let (_, pageError) = await router.route(
            namespace: "history", method: "addUrl", params: ["url": "https://b.test/"],
            extensionId: extensionId, fromWorker: false, registry: profileB.extensions
        )
        let (_, workerError) = await router.route(
            namespace: "history", method: "addUrl", params: ["url": "https://b.test/"],
            extensionId: extensionId, fromWorker: true, registry: profileB.extensions
        )
        let (selfInfo, selfError) = await router.route(
            namespace: "management", method: "getSelf", params: [:],
            extensionId: extensionId, fromWorker: true, registry: profileB.extensions
        )

        XCTAssertNotNil(pageError)
        XCTAssertNotNil(workerError)
        XCTAssertNil(try profileB.history.entry(forURL: "https://b.test/"))
        XCTAssertNil(selfError)
        XCTAssertEqual((selfInfo as? [String: Any])?["id"] as? String, extensionId)
    }

    func testCallFromAnExtensionMissingInTheChannelProfileFailsClosed() async throws {
        let router = factory.gapRouter
        let extensionId = try await loadExtension(into: profileB)

        let (_, error) = await router.route(
            namespace: "bookmarks", method: "create",
            params: ["parentId": "1", "title": "t", "url": "https://b.test"],
            extensionId: extensionId, fromWorker: false, registry: profileA.extensions
        )

        XCTAssertNotNil(error)
        XCTAssertEqual(try profileA.bookmarks.getChildren(parentId: "1").count, 0)
        XCTAssertEqual(try profileB.bookmarks.getChildren(parentId: "1").count, 0)
    }

    func testOnlyTheWorkerReportTurnsOnGapEventFiltering() async throws {
        let router = factory.gapRouter
        let registry = profileA.extensions
        let extensionId = try await loadExtension(into: profileA)

        registry.gapEvents.emit("bookmarks", "onCreated", args: [], to: [extensionId])
        _ = await router.route(
            namespace: "events", method: "listen", params: ["events": ["history.onVisited"]],
            extensionId: extensionId, fromWorker: false, registry: registry
        )
        registry.gapEvents.emit("bookmarks", "onChanged", args: [], to: [extensionId])
        _ = await router.route(
            namespace: "events", method: "listen", params: ["events": [String]()],
            extensionId: extensionId, fromWorker: true, registry: registry
        )
        registry.gapEvents.emit("bookmarks", "onRemoved", args: [], to: [extensionId])
        registry.gapEvents.emit("history", "onVisited", args: [], to: [extensionId])

        XCTAssertEqual(
            registry.gapEvents.undelivered(to: extensionId).map(\.event),
            ["onExtensionLoaded", "onCreated", "onChanged", "onVisited"],
            "a page's listeners count once the worker has reported its own (the install's event came before)"
        )
    }

    func testEventsForAStoppedWorkerKeepTheNewestInOrder() async throws {
        let registry = profileA.extensions
        let extensionId = try await loadExtension(into: profileA)

        for index in 0..<300 {
            registry.emitGapEvent("bookmarks", "onRemoved", args: [String(index)], requiredPermission: "bookmarks")
        }

        let kept = registry.gapEvents.undelivered(to: extensionId).compactMap { $0.args.first as? String }
        XCTAssertEqual(kept, (44..<300).map(String.init))
    }

    func testStoppedWorkerWakesForAnEventAndCallsBackOverItsChannel() async throws {
        let registry = profileA.extensions
        let dir = tempDir.appendingPathComponent("worker-ext")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"manifest_version": 3, "name": "Worker", "version": "1.0", "permissions": ["bookmarks"], "background": {"service_worker": "sw.js"}}
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.bookmarks.onCreated.addListener((id, node) => {
          if (node.title === 'ping') chrome.bookmarks.create({ parentId: '1', title: 'pong' });
        });
        """.write(to: dir.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: dir)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        XCTAssertFalse(registry.gapEvents.isConnected(extensionId))

        registry.emitGapEvent("bookmarks", "onCreated", args: ["9", ["id": "9", "title": "ping"]], requiredPermission: "bookmarks")

        let answered = await pollUntil(timeout: 10) {
            (try? self.profileA.bookmarks.getChildren(parentId: "1").contains { $0.title == "pong" }) == true
        }
        XCTAssertTrue(answered, "the woken worker received the event and its call reached the profile")
        XCTAssertTrue(registry.gapEvents.isConnected(extensionId))
        XCTAssertEqual(registry.lifecycle.worker(of: extensionId), .running)
        // WebKit confirms the delivery on its own schedule, possibly after the worker's call.
        let confirmed = await pollUntil { registry.gapEvents.undelivered(to: extensionId).isEmpty }
        XCTAssertTrue(confirmed)
    }

    /// An idle worker lets its channel go, so WebKit unloads it on its own 30 s schedule instead of
    /// about 2.5 minutes later, and it still hears the events sent while it idles and after it unloaded.
    func testAnIdleWorkerUnloadsOnChromesScheduleAndHearsLaterEvents() async throws {
        let registry = profileA.extensions
        let dir = tempDir.appendingPathComponent("idle-worker-ext")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"manifest_version": 3, "name": "Idle", "version": "1.0", "permissions": ["bookmarks"], "background": {"service_worker": "sw.js"}}
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.bookmarks.onCreated.addListener((id, node) => {
          if (node.title.startsWith('ping')) chrome.bookmarks.create({ parentId: '1', title: node.title.replace('ping', 'pong') });
        });
        """.write(to: dir.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: dir)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: extensionId))
        let backgroundWebView = { context.perform(NSSelectorFromString("_backgroundWebView"))?.takeUnretainedValue() as? WKWebView }
        let ping = { (index: Int) in
            registry.emitGapEvent("bookmarks", "onCreated", args: ["\(index)", ["id": "\(index)", "title": "ping-\(index)"]], requiredPermission: "bookmarks")
        }
        let answered = { (index: Int) in
            await pollUntil(timeout: 10) {
                (try? self.profileA.bookmarks.getChildren(parentId: "1").contains { $0.title == "pong-\(index)" }) == true
            }
        }

        ping(1)
        let answeredFirst = await answered(1)
        XCTAssertTrue(answeredFirst, "the stopped worker woke for the event")
        let loaded = ContinuousClock.now
        let worker = try XCTUnwrap(backgroundWebView())

        let closed = await pollUntil(timeout: 40) { !registry.gapEvents.isConnected(extensionId) }
        XCTAssertTrue(closed, "the idle worker lets its channel go")
        let closedAfter = ContinuousClock.now - loaded
        XCTAssertTrue(backgroundWebView() === worker, "WebKit still runs the worker without its channel")

        ping(2)
        let answeredSecond = await answered(2)
        XCTAssertTrue(answeredSecond, "the running worker reconnected for the event")
        XCTAssertTrue(backgroundWebView() === worker, "it heard it without a restart")
        let lastActivity = ContinuousClock.now

        let unloaded = await pollUntil(timeout: 90) { backgroundWebView() == nil }
        XCTAssertTrue(unloaded, "WebKit unloads the idle worker")
        let unloadedAfter = ContinuousClock.now - lastActivity
        // The worker idles 20 s, then WebKit's next 30 s check unloads it.
        XCTAssertLessThan(unloadedAfter, .seconds(55))
        print("idle worker: channel closed \(closedAfter) after its last event, unloaded \(unloadedAfter) after its next one")

        ping(3)
        let answeredThird = await answered(3)
        XCTAssertTrue(answeredThird, "the unloaded worker started again for the event")
        let confirmed = await pollUntil { registry.gapEvents.undelivered(to: extensionId).isEmpty }
        XCTAssertTrue(confirmed)
    }

    func testCookieChangesReachHostPermittedExtensionsWithChromeChangeInfo() async throws {
        let registry = profileA.extensions
        let extensionId = try await loadExtension(into: profileA, permissions: ["cookies"], hostPermissions: ["*://*.a.test/*"])
        let store = WKWebsiteDataStore(forIdentifier: profileA.profileId).httpCookieStore
        func cookie(_ domain: String, _ value: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: value, .domain: domain, .path: "/", .secure: "TRUE"]))
        }
        func changes() -> [[String: Any]] {
            registry.gapEvents.undelivered(to: extensionId)
                .filter { $0.namespace == "cookies" && $0.event == "onChanged" }
                .compactMap { $0.args.first as? [String: Any] }
        }
        // The tracker's first read only takes the baseline.
        await registry.cookieChangesReported()

        await store.setCookie(try cookie(".a.test", "1"))
        await store.setCookie(try cookie("b.test", "1"))
        let added = await pollUntil { changes().count == 1 }
        await store.setCookie(try cookie(".a.test", "2"))
        let overwritten = await pollUntil { changes().count == 3 }
        await store.deleteCookie(try cookie(".a.test", "2"))
        let removed = await pollUntil { changes().count == 4 }

        XCTAssertTrue(added && overwritten && removed, "got \(changes())")
        XCTAssertEqual(changes().map { $0["cause"] as? String }, ["explicit", "overwrite", "explicit", "explicit"])
        XCTAssertEqual(changes().map { $0["removed"] as? Bool }, [false, true, false, true])
        let first = try XCTUnwrap(changes().first?["cookie"] as? [String: Any])
        XCTAssertEqual(first["domain"] as? String, ".a.test")
        XCTAssertEqual(first["hostOnly"] as? Bool, false)
        XCTAssertEqual(first["value"] as? String, "1")
        XCTAssertEqual(first["secure"] as? Bool, true)
        XCTAssertEqual(first["session"] as? Bool, true)
        XCTAssertNil(first["expirationDate"])
        XCTAssertEqual((changes()[1]["cookie"] as? [String: Any])?["value"] as? String, "1", "an overwrite reports the replaced cookie")
    }
}
