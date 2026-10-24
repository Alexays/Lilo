import Network
import XCTest
import GRDB
import WebKit
@testable import Lilo

@MainActor
final class ProfileExtensionRegistryTests: XCTestCase {
    private var registry: ProfileExtensionRegistry!
    private var tempDir: URL!

    /// Registries are built with `extensionsBaseDirectory: tempDir`, so their per-profile store
    /// lives under the test temp dir, never the user's real Application Support.
    private func profileSupportDirectory(for profileId: UUID) -> URL {
        tempDir.appendingPathComponent("Profiles/\(profileId.uuidString)", isDirectory: true)
    }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = try makeTestExtensionRegistry(in: tempDir)
    }

    override func tearDown() {
        registry?.teardown()
        registry = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func createPermissionsExtension(named directoryName: String, displayName: String = "Permissions Test") throws -> URL {
        let extDir = tempDir.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"\(displayName)","version":"1.0","permissions":["storage","tabs"],"host_permissions":["https://*/*"]}
        """
        try manifest.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return extDir
    }

    private func createBackgroundExtension(named directoryName: String, displayName: String = "Background Test") throws -> URL {
        let extDir = tempDir.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        // A shortcut with no key: the manifest warning a working extension can carry.
        let manifest = """
        {"manifest_version":3,"name":"\(displayName)","version":"1.0","background":{"service_worker":"background.js"},
         "commands":{"open":{"description":"Open","suggested_key":{"default":"Ctrl+Shift"}}}}
        """
        try manifest.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "self.addEventListener('install', () => {});".write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        return extDir
    }

    private func createActionExtension(named directoryName: String, displayName: String = "Action Test") throws -> URL {
        let extDir = tempDir.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"\(displayName)","version":"1.0","action":{"default_title":"Action"}}
        """
        try manifest.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return extDir
    }

    private func createContentScriptExtension(named directoryName: String, displayName: String = "Content Script Test") throws -> URL {
        let extDir = tempDir.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"\(displayName)","version":"1.0","content_scripts":[{"matches":["https://example.com/*"],"js":["content.js"]}]}
        """
        try manifest.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('content');".write(to: extDir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        return extDir
    }

    private func extensionBridgePayload(for id: String) -> [String: Any]? {
        registry.extensionBridgePayloads(activeTab: nil).first { $0["id"] as? String == id }
    }

    // MARK: - Background revive

    /// Loads an extension degraded by a failed WK-compat preparation but with a valid vendor worker, so a successful
    /// revive (a working `loadBackgroundContent()`) is observable.
    private func loadDegradedButReloadableExtension(named directoryName: String) async throws -> String {
        let extDir = try createBackgroundExtension(named: directoryName, displayName: directoryName)
        try Data().write(to: extDir.appendingPathComponent("_lilo"))
        try await registry.load(from: extDir)
        let id = registry.loadedExtensions.first { $0.context.webExtension.displayName == directoryName }!.id
        XCTAssertEqual(extensionBridgePayload(for: id)?["runtimeStatus"] as? String, "degraded", "preparation failure must load degraded")
        return id
    }

    /// A healthy background extension whose vendor worker loads and whose preparation succeeded, so it
    /// starts "loaded". Used to exercise the *runtime* degradation path in isolation from the
    /// sticky preparation signal.
    private func loadHealthyBackgroundExtension(named directoryName: String) async throws -> String {
        let extDir = try createBackgroundExtension(named: directoryName, displayName: directoryName)
        try await registry.load(from: extDir)
        let id = registry.loadedExtensions.first { $0.context.webExtension.displayName == directoryName }!.id
        XCTAssertEqual(extensionBridgePayload(for: id)?["runtimeStatus"] as? String, "loaded", "a healthy extension must load loaded")
        return id
    }

    /// The pure debounce predicate is the loop guard: a never-attempted extension may try; one that
    /// just tried may not (that throttles out the error notification a failed attempt itself emits);
    /// one that tried long ago may try again.
    func testShouldAttemptReviveDebounce() {
        let now = Date()
        XCTAssertTrue(BackgroundSupervisor.shouldAttempt(lastAttempt: nil, now: now, debounce: 10))
        XCTAssertFalse(BackgroundSupervisor.shouldAttempt(lastAttempt: now, now: now, debounce: 10))
        XCTAssertFalse(BackgroundSupervisor.shouldAttempt(lastAttempt: now.addingTimeInterval(-5), now: now, debounce: 10))
        XCTAssertTrue(BackgroundSupervisor.shouldAttempt(lastAttempt: now.addingTimeInterval(-30), now: now, debounce: 10))
    }

    /// Restarting a background that is still loading makes WebKit destroy the worker's global scope
    /// under its running script, which segfaults the service-worker process. A worker on its way up
    /// also has no heartbeat yet, so every restart path must consult the load guard first.
    func testRestartPathsAreSkippedWhileABackgroundLoadIsInFlight() async throws {
        let id = try await loadHealthyBackgroundExtension(named: "InFlightGuard")
        let loading = Task { await registry.backgrounds.load(id) }
        for _ in 0..<1000 where !registry.backgrounds.isLoadInFlight(id) { await Task.yield() }
        XCTAssertTrue(registry.backgrounds.isLoadInFlight(id), "the load must mark the extension as loading")

        let revived = await registry.backgrounds.reviveIfNeeded(id)

        XCTAssertFalse(revived, "a revive must not restart a worker that is already loading")
        await loading.value
        XCTAssertFalse(registry.backgrounds.isLoadInFlight(id), "the guard clears once the load resolves")
    }

    /// A revive marks runtime-degraded before the reload (observable, and honest if the reload hangs)
    /// and clears it once the reload succeeds, returning the extension to "loaded".
    func testReviveClearsRuntimeDegradationOnSuccess() async throws {
        let id = try await loadHealthyBackgroundExtension(named: "ReviveClear")
        var sawDegraded = false
        registry.onExtensionsChanged = { [weak registry] in
            if registry?.extensionBridgePayloads(activeTab: nil).first(where: { $0["id"] as? String == id })?["runtimeStatus"] as? String == "degraded" {
                sawDegraded = true
            }
        }

        let revived = await registry.backgrounds.reviveIfNeeded(id)

        XCTAssertTrue(revived, "a valid worker reloads successfully")
        XCTAssertTrue(sawDegraded, "the revive marks runtime-degraded before the reload")
        XCTAssertEqual(extensionBridgePayload(for: id)?["runtimeStatus"] as? String, "loaded",
                       "a successful reload clears the runtime degradation")
    }

    /// A preparation-degraded extension (sticky, on-disk) must stay degraded even when its vendor worker reloads: a runtime
    /// revive must not report the broken-on-disk extension as healthy.
    func testReviveKeepsPreparationDegradedExtensionDegraded() async throws {
        let id = try await loadDegradedButReloadableExtension(named: "PrepStays")

        let revived = await registry.backgrounds.reviveIfNeeded(id)

        XCTAssertTrue(revived, "the vendor worker still loads")
        XCTAssertEqual(extensionBridgePayload(for: id)?["runtimeStatus"] as? String, "degraded",
                       "a successful revive must not clear preparation degradation")
    }

    /// The loop guard end to end: a second revive arriving within the debounce window makes no fresh
    /// attempt: the recorded attempt timestamp is unchanged.
    func testReviveIsDebouncedToASingleAttempt() async throws {
        let id = try await loadHealthyBackgroundExtension(named: "ReviveDebounce")

        let first = await registry.backgrounds.reviveIfNeeded(id)
        let firstAttempt = try XCTUnwrap(registry.backgrounds.health(for: id)?.lastReviveAttempt)

        let second = await registry.backgrounds.reviveIfNeeded(id)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "a second revive within the debounce window must be throttled")
        XCTAssertEqual(registry.backgrounds.health(for: id)?.lastReviveAttempt, firstAttempt, "a debounced revive must not record a new attempt")
    }

    /// Driving the real notification handler with what a working extension records (here a manifest
    /// warning): only a background that failed to load is revived, so nothing restarts or degrades.
    func testHandleBackgroundErrorNotificationLeavesAWorkingBackgroundAlone() async throws {
        let id = try await loadHealthyBackgroundExtension(named: "ReviveNotify")
        let context = try XCTUnwrap(registry.context(for: id))
        XCTAssertFalse(context.errors.isEmpty, "a recorded error must be present to drive the handler")

        registry.backgrounds.contextErrorsChanged(id)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(registry.backgrounds.health(for: id)?.lastReviveAttempt)
        XCTAssertEqual(extensionBridgePayload(for: id)?["runtimeStatus"] as? String, "loaded")
    }

    func testLoadInvalidURLThrows() async {
        let invalidURL = tempDir.appendingPathComponent("nonexistent", isDirectory: true)
        do {
            try await registry.load(from: invalidURL)
            XCTFail("Expected throw for invalid URL")
        } catch {
            // expected
        }
    }

    func testLoadingIdlePermissionExtensionStartsIdlePoller() async throws {
        let registry = self.registry!
        let handler = IdleBridgeHandler(registriesProvider: { [registry] })
        XCTAssertFalse(handler.isPolling)

        let extDir = tempDir.appendingPathComponent("idle_extension")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Idle Test","version":"1.0","permissions":["idle"]}
        """
        try manifest.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try await registry.load(from: extDir)
        for _ in 0..<10 { await Task.yield() }   // drain the notification's main-actor hop

        XCTAssertTrue(handler.isPolling, "a runtime load holding the idle permission must wake the poller")
    }

    func testLoadingExtensionWithoutIdlePermissionLeavesPollerStopped() async throws {
        let registry = self.registry!
        let handler = IdleBridgeHandler(registriesProvider: { [registry] })
        let extDir = try createMinimalExtension(named: "no_idle_extension", in: tempDir)

        try await registry.load(from: extDir)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(handler.isPolling)
    }

    func testMarkActionPopupUnavailableDegradesRuntime() async throws {
        let extDir = try createActionExtension(named: "popup_unavailable_extension", displayName: "Popup Unavailable")

        try await registry.load(from: extDir)
        let id = registry.loadedExtensions.first!.id
        XCTAssertEqual(extensionBridgePayload(for: id)?["runtimeStatus"] as? String, "loaded")

        registry.backgrounds.markPopupUnavailable(id)

        XCTAssertEqual(extensionBridgePayload(for: id)?["runtimeStatus"] as? String, "degraded",
                       "a popup that WebKit could not present must surface as degraded, not fail silently")
    }

    /// Installs workers that show in their action title that they ran and each runtime.onInstalled and
    /// onStartup they hear: classic, module, and one adding its listeners after its first import.
    private func installLifecycleRecorders() async throws -> [(name: String, id: String)] {
        let recorder = """
        const heard = ['ran'];
        const record = (name) => (details) => {
          heard.push([name, details?.reason, details?.previousVersion].filter(Boolean).join(':'));
          chrome.action.setTitle({ title: heard.join(' ') });
        };
        chrome.action.setTitle({ title: 'ran' });
        """
        let listen = "chrome.runtime.onInstalled.addListener(record('installed'));\nchrome.runtime.onStartup.addListener(record('startup'));"
        let workers: [(name: String, background: [String: String], files: [String: String])] = [
            ("classic", ["service_worker": "background.js"], ["background.js": recorder + listen]),
            ("module", ["service_worker": "background.js", "type": "module"], [
                "recorder.js": recorder + "export { record };",
                "background.js": "import { record } from './recorder.js';\n" + listen
            ]),
            ("imported", ["service_worker": "background.js"], [
                "recorder.js": recorder,
                "background.js": "importScripts('recorder.js');\n" + listen
            ])
        ]
        var installed: [(name: String, id: String)] = []
        for worker in workers {
            let extDir = tempDir.appendingPathComponent("lifecycle_\(worker.name)")
            try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["manifest_version": 3, "name": worker.name, "version": "1.0", "action": [:], "background": worker.background]
            try JSONSerialization.data(withJSONObject: manifest).write(to: extDir.appendingPathComponent("manifest.json"))
            for (file, source) in worker.files { try source.write(to: extDir.appendingPathComponent(file), atomically: true, encoding: .utf8) }
            try await registry.load(from: extDir)
            installed.append((worker.name, try XCTUnwrap(registry.loadedExtensions.last?.id)))
        }
        return installed
    }

    /// Starts the worker and checks its title once nothing more arrives.
    private func assertWorkerHeard(_ expected: String, _ id: String, _ message: String) async throws {
        let context = try XCTUnwrap(registry.context(for: id))
        _ = await registry.backgrounds.load(id)
        _ = await pollUntil(timeout: 10) { context.action(for: nil)?.label == expected }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(context.action(for: nil)?.label, expected, message)
    }

    /// As in Chrome, a new install's worker hears runtime.onInstalled once and no onStartup, even right
    /// after launch, and an update hears "update" with the version it replaces.
    func testWorkersHearOnInstalledOnceForAnInstallAndAnUpdate() async throws {
        let installed = try await installLifecycleRecorders()
        for (name, id) in installed {
            try await assertWorkerHeard("ran installed:install", id, "\(name) worker on install")
        }

        let (name, id) = installed[0]
        let sourcePath = try XCTUnwrap(registry.loadedExtensions.first { $0.id == id }?.sourcePath)
        await registry.disable(extensionId: id)
        let manifestURL = URL(fileURLWithPath: sourcePath).appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["version"] = "2.0"
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try await registry.enable(extensionId: id)
        try await assertWorkerHeard("ran installed:update:1.0", id, "\(name) worker on update")
    }

    /// As in Chrome, the event that starts a worker comes after the answers to the calls its top-level
    /// code made: Glasp's onInstalled clears and recreates the menus its top-level code is creating.
    func testOnInstalledComesAfterTheAnswersToTopLevelCalls() async throws {
        let extDir = tempDir.appendingPathComponent("ordered")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Ordered", "version": "1.0", "permissions": ["contextMenus", "storage"], "action": [:],
            "background": ["service_worker": "background.js", "type": "module"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: extDir.appendingPathComponent("manifest.json"))
        try """
            const order = [];
            browser.contextMenus.removeAll().then(() => order.push('answered'));
            browser.runtime.onInstalled.addListener(() => {
                order.push('installed');
                chrome.action.setTitle({ title: order.join(',') });
            });
            """.write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.last?.id)
        try await assertWorkerHeard("answered,installed", id, "the worker hears onInstalled once removeAll answered")
    }

    /// As in Chrome, onInstalled waits for the content script registrations of the worker's startup:
    /// Tactiq's onInstalled unregisters and registers again what its startup is registering.
    func testOnInstalledComesAfterStartupRegistrations() async throws {
        let extDir = tempDir.appendingPathComponent("registering")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Registering", "version": "1.0", "permissions": ["scripting"],
            "host_permissions": ["*://meet.google.com/*"], "action": [:], "background": ["service_worker": "background.js"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: extDir.appendingPathComponent("manifest.json"))
        try "".write(to: extDir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        try """
            const order = [];
            const log = (step) => { order.push(step); chrome.action.setTitle({ title: order.join(',') }); };
            async function reset(tag) {
              await chrome.scripting.unregisterContentScripts({ ids: ['meet'] }).catch(() => {});
              await chrome.scripting.registerContentScripts([{ id: 'meet', js: ['content.js'], matches: ['*://meet.google.com/*'] }])
                .then(() => log(tag + ' registered'), (error) => log(tag + ' ' + error.message));
            }
            chrome.runtime.onInstalled.addListener(() => { log('installed'); reset('again'); });
            reset('startup');
            """.write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.last?.id)
        try await assertWorkerHeard("startup registered,installed,again registered", id, "the startup registration answers before onInstalled")
    }

    /// A worker's WebSocket opens, exchanges text and bytes and closes, where WebKit's own freezes the
    /// worker (WEBKIT-GAPS.md, gap 33): Keeper's worker stopped answering its content scripts.
    func testAWorkersWebSocketExchangesMessages() async throws {
        let listener = try NWListener(using: {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            return parameters
        }(), on: .any)
        listener.newConnectionHandler = { connection in
            func echo() {
                connection.receiveMessage { data, context, _, error in
                    guard error == nil, let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return }
                    let reply = NWProtocolWebSocket.Metadata(opcode: metadata.opcode)
                    connection.send(content: data, contentContext: NWConnection.ContentContext(identifier: "echo", metadata: [reply]), completion: .idempotent)
                    echo()
                }
            }
            connection.start(queue: .global())
            echo()
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() } }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await value in ready { port = value }
        defer { listener.cancel() }

        let extDir = tempDir.appendingPathComponent("socket")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Socket", "version": "1.0", "action": [:], "background": ["service_worker": "background.js"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: extDir.appendingPathComponent("manifest.json"))
        try """
            const heard = [];
            const log = (step) => { heard.push(step); chrome.action.setTitle({ title: heard.join(' ') }); };
            const socket = new WebSocket('ws://127.0.0.1:\(port)/');
            socket.binaryType = 'arraybuffer';
            socket.onopen = () => { log('open'); socket.send('ping'); };
            socket.onmessage = (event) => {
              if (typeof event.data === 'string') { log(event.data); socket.send(new Uint8Array([1, 2, 3])); return; }
              log('bytes:' + new Uint8Array(event.data).join(','));
              socket.close(1000, 'done');
            };
            socket.addEventListener('close', (event) => log('close:' + event.code));
            """.write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        // The gap channel needs the app's router, which a bare registry has not.
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (_, registry) = try browserContext.makeExtensionWindow()
        try await registry.load(from: extDir)
        let context = try XCTUnwrap(registry.loadedExtensions.last?.context)
        let closed = await pollUntil { context.action(for: nil)?.label.contains("close") == true }
        XCTAssertTrue(closed)
        XCTAssertEqual(context.action(for: nil)?.label, "open ping bytes:1,2,3 close:1000", "the worker's socket opens, echoes text and bytes, and closes")
    }

    /// Chrome tells a re-enabled worker, or one its extension reloads unchanged, neither event, however
    /// long after the controller it loads.
    func testReEnabledOrReloadedWorkerHearsNeitherOnInstalledNorOnStartup() async throws {
        let start = ContinuousClock.now
        let installed = try await installLifecycleRecorders()
        try await Task.sleep(until: start + .seconds(6), clock: .continuous)
        for (name, id) in installed {
            let sourcePath = try XCTUnwrap(registry.loadedExtensions.first { $0.id == id }?.sourcePath)
            await registry.disable(extensionId: id)
            try await registry.enable(extensionId: id)
            try await assertWorkerHeard("ran", id, "\(name) worker re-enabled")

            // What the background supervisor's full reload does.
            await registry.unload(extensionId: id, removePersistedRecord: false)
            try await registry.load(from: URL(fileURLWithPath: sourcePath), extensionId: id)
            try await assertWorkerHeard("ran", id, "\(name) worker reloaded")
        }
    }

    /// An event sent between an unload and the next worker's connection waits for that worker instead
    /// of going to the unloaded one.
    func testAnUnloadedWorkerTakesNoEventsMeantForTheNextLoad() async throws {
        let extDir = try createBackgroundExtension(named: "reloaded_worker", displayName: "Reloaded")
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        _ = await registry.backgrounds.load(id)
        let connected = await pollUntil(timeout: 10) { self.registry.gapEvents.isConnected(id) }
        XCTAssertTrue(connected)

        await registry.unload(extensionId: id, removePersistedRecord: false)
        XCTAssertFalse(registry.gapEvents.isConnected(id), "the unloaded worker's channel is let go at once")
        try await registry.load(from: extDir, extensionId: id)
        registry.gapEvents.emit("runtime", "onStartup", args: [], to: [id], wakes: false)
        XCTAssertEqual(registry.gapEvents.undelivered(to: id).map(\.event).last, "onStartup")
    }

    /// A launch restore hears onStartup and no onInstalled, as in Chrome, however long after the
    /// controller it loads.
    func testWorkersRestoredLateHearOnStartupOnly() async throws {
        let profileId = TestProfileIds.next()
        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        let installed = try await installLifecycleRecorders()
        for (_, id) in installed { _ = await registry.backgrounds.load(id) }
        registry.teardown()

        registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        try await Task.sleep(for: .seconds(6))
        await registry.restore()

        for (name, id) in installed {
            try await assertWorkerHeard("ran startup", id, "\(name) worker restored")
        }
    }

    /// A deferred launch strands WebKit's keep-awake activity on a placeholder process, and the worker is
    /// then terminated seconds after load.
    func testBackgroundWebViewLaunchesItsProcessUpFront() async throws {
        let extDir = try createBackgroundExtension(named: "eager_background_extension", displayName: "Eager Background")
        try await registry.load(from: extDir)
        let id = registry.loadedExtensions.first!.id
        await registry.backgrounds.load(id)

        let context = try XCTUnwrap(registry.context(for: id))
        let getter = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: getter) else { throw XCTSkip("WebKit does not expose the background web view") }
        let webView = try XCTUnwrap(context.perform(getter)?.takeUnretainedValue() as? WKWebView)
        XCTAssertEqual(webView.configuration.value(forKey: "_delaysWebProcessLaunchUntilFirstLoad") as? Bool, false)
    }

    func testLoadBackgroundContentIsNoOpForExtensionWithoutBackground() async throws {
        let extDir = try createMinimalExtension(named: "no_background_extension", displayName: "No Background", in: tempDir)
        try await registry.load(from: extDir)
        let id = registry.loadedExtensions.first!.id

        await registry.backgrounds.load(id)
        let payload = try XCTUnwrap(extensionBridgePayload(for: id))

        XCTAssertEqual(payload["runtimeStatus"] as? String, "loaded")
    }

    func testBackgroundDiagnosticsSnapshotIncludesContextErrorsWithoutWakeAttempt() async throws {
        let extDir = try createBackgroundExtension(named: "context_error_diagnostics_extension", displayName: "Context Error Diagnostics")

        try await registry.load(from: extDir)
        let id = registry.loadedExtensions.first!.id

        let diagnostics = registry.backgroundDiagnosticsSnapshots()
        let snapshot = try XCTUnwrap(diagnostics.first { $0["id"] as? String == id })
        let contextErrors = try XCTUnwrap(snapshot["contextErrors"] as? [[String: Any]])

        XCTAssertNil(snapshot["lastWakeReason"] as? String)
        XCTAssertFalse(contextErrors.isEmpty)
        XCTAssertTrue((contextErrors.first?["description"] as? String)?.contains("WKWebExtensionErrorDomain") == true)
    }

    func testUnloadRemovesTheExtensionAndItsRuntimeState() async throws {
        let extDir = try createMinimalExtension(named: "runtime_state_unload_extension", in: tempDir)

        try await registry.load(from: extDir)
        let id = registry.loadedExtensions.first!.id
        registry.updateActionColor(for: id) { colors in
            colors.badgeColor = "#ff0000"
            colors.badgeTextColor = "#ffffff"
        }
        registry.actionDidChange(for: id)
        XCTAssertEqual(extensionBridgePayload(for: id)?["iconVersion"] as? Int, 1)

        await registry.unload(extensionId: id)

        XCTAssertEqual(registry.loadedExtensions.count, 0)
        XCTAssertNil(registry.actionColors(of: id))
        XCTAssertNil(extensionBridgePayload(for: id))
        XCTAssertNil(registry.backgroundDiagnosticsSnapshots().first { $0["id"] as? String == id })
    }

    func testUnloadClosesTheExtensionsPopupFirst() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, extensions) = try browserContext.makeExtensionWindow()
        window.window?.orderFrontRegardless()
        let folder = tempDir.appendingPathComponent("popup_extension")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Popup","version":"1.0","action":{"default_popup":"popup.html"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<p>popup</p>".write(to: folder.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try await extensions.load(from: folder)
        let id = try XCTUnwrap(extensions.loadedExtensions.first?.id)
        let context = try XCTUnwrap(extensions.context(for: id))
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let adapter = window.tabManager.tabAdapter(for: tab.id)
        context.performAction(for: adapter)
        let popover = context.action(for: adapter)?.popupPopover
        let shown = await pollUntil(timeout: 10) { popover?.isShown == true }
        XCTAssertTrue(shown, "the popup shows")

        await extensions.unload(extensionId: id)

        // WebKit's popover crashes when it finishes closing after its context unloaded.
        XCTAssertEqual(popover?.isShown, false, "the popup closes before its context unloads")
        XCTAssertFalse(extensions.delegate.hasOpenActionPopover)
    }

    // MARK: - Teardown (cache eviction)

    /// Teardown unloads the runtime but leaves the persisted record enabled, so a revisit
    /// reconstructs the full extension list cold through restore() (the restore path itself is
    /// covered by testRestoreLoadsEnabledExtensionsFromDatabase).
    func testTeardownUnloadsContextsButKeepsPersistedRecordEnabled() async throws {
        let profileId = TestProfileIds.next()
        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        let registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        let extDir = try createMinimalExtension(named: "teardown_persist", displayName: "Teardown Persist", in: tempDir)
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)

        registry.teardown()

        XCTAssertTrue(registry.loadedExtensions.isEmpty)
        let stored = try await storage.load(id: id)
        XCTAssertTrue(stored?.isEnabled ?? false, "teardown must not disable or remove the persisted record")

        let revisited = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        await revisited.restore()
        XCTAssertEqual(revisited.loadedExtensions.count, 1, "a revisit after teardown must reload the persisted extension")
    }

    /// WebKit's checked completion handlers crash if deallocated uninvoked, so teardown must
    /// resolve every pending permission prompt (as denied) rather than drop it.
    func testTeardownDeniesPendingPermissionRequests() {
        var granted: Bool?
        registry.pendingPermissionRequests["pending"] = { granted = $0 }

        registry.teardown()

        XCTAssertEqual(granted, false)
        XCTAssertTrue(registry.pendingPermissionRequests.isEmpty)
    }

    /// The registry strongly holds its WKWebExtensionController and every loaded context; eviction
    /// only frees those processes if dropping the cache reference actually deallocates the graph.
    func testRegistryDeallocatesAfterTeardown() async throws {
        var registry: ProfileExtensionRegistry? = try makeTestExtensionRegistry(in: tempDir)
        let extDir = try createMinimalExtension(named: "teardown_dealloc", displayName: "Teardown Dealloc", in: tempDir)
        try await registry?.load(from: extDir)
        weak var weakRegistry = registry

        registry?.teardown()
        registry = nil

        for _ in 0..<20 where weakRegistry != nil { await Task.yield() }
        XCTAssertNil(weakRegistry, "an evicted registry must deallocate, or its controller and workers stay resident")
    }

    // MARK: - Auto-update

    /// The first check waits for what is left of the interval since the saved check, from 90s to 5h.
    func testFirstUpdateCheckWaitsForTheRestOfTheIntervalSinceTheSavedCheck() async throws {
        let database = try TemporaryProfileDatabase(schema: .global)
        defer { database.tearDown() }
        let settings = SettingsStore(dbPool: database.pool)
        registry.settingsStore = settings
        let key = "extensionUpdateLastCheck.\(registry.profileId.uuidString)"
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let interval = ExtensionUpdater.checkInterval
        let cases: [(lastCheck: TimeInterval?, delay: Duration)] = [
            (nil, .seconds(90)),
            (now.timeIntervalSince1970 - 3600, .seconds(interval - 3600)),
            (now.timeIntervalSince1970 - interval + 10, .seconds(90)),
            (now.timeIntervalSince1970 - 2 * interval, .seconds(90)),
            (now.timeIntervalSince1970 + 3600, .seconds(interval)),
        ]
        for (lastCheck, delay) in cases {
            if let lastCheck { settings.set(key, value: String(lastCheck)) } else { settings.remove(key) }
            let delays = AsyncStream<Duration>.makeStream()
            registry.updater.start(now: now) { duration in
                delays.continuation.yield(duration)
                try? await Task.sleep(for: .seconds(3600))
            }
            var iterator = delays.stream.makeAsyncIterator()
            let firstDelay = await iterator.next()
            XCTAssertEqual(firstDelay, delay, "last check \(String(describing: lastCheck))")
            registry.teardown()
        }
        withExtendedLifetime(settings) {}
    }

    func testSavedUpdateCheckTimeIsShownBeforeTheFirstCheckOfTheLaunch() throws {
        let database = try TemporaryProfileDatabase(schema: .global)
        defer { database.tearDown() }
        let settings = SettingsStore(dbPool: database.pool)
        registry.settingsStore = settings
        settings.set("extensionUpdateLastCheck.\(registry.profileId.uuidString)", value: "1234.5")

        registry.updater.start { _ in try? await Task.sleep(for: .seconds(3600)) }

        XCTAssertEqual(registry.updater.status["lastCheck"] as? TimeInterval, 1234.5)
        XCTAssertNil(registry.updater.status["checking"])
        registry.teardown()
        withExtendedLifetime(settings) {}
    }

    func testExtensionBridgePayloadDetectsContentScripts() async throws {
        let extDir = try createContentScriptExtension(named: "content_script_payload_extension", displayName: "Content Script Payload")

        try await registry.load(from: extDir)
        let payload = try XCTUnwrap(registry.extensionBridgePayloads(activeTab: nil).first)

        XCTAssertEqual(payload["hasContentScripts"] as? Bool, true)
    }

    func testExtensionBridgePayloadIncludesManifestPermissions() async throws {
        let extDir = try createPermissionsExtension(named: "permissions_payload_extension", displayName: "Permissions Payload")

        try await registry.load(from: extDir)
        let payload = try XCTUnwrap(registry.extensionBridgePayloads(activeTab: nil).first)

        XCTAssertEqual(payload["permissions"] as? [String], ["storage", "tabs"])
        XCTAssertEqual(payload["hostPermissions"] as? [String], ["https://*/*"])
    }

    func testExtensionBridgePayloadCacheInvalidatesOnActionColorChange() async throws {
        let extDir = try createMinimalExtension(named: "payload_cache_invalidation_extension", displayName: "Payload Cache Invalidation", in: tempDir)

        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        _ = registry.extensionBridgePayloads(activeTab: nil)

        registry.updateActionColor(for: id) { $0.badgeColor = "#123456" }
        let payload = try XCTUnwrap(registry.extensionBridgePayloads(activeTab: nil).first)

        XCTAssertEqual(payload["badgeColor"] as? String, "#123456")
    }

    func testActiveTabBadgeColorWinsOverTheExtensionColor() async throws {
        try await registry.load(from: try createMinimalExtension(named: "tab_badge_color_extension", in: tempDir))
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let tab = TabExtensionAdapter(engineTab: WKWebViewTab(id: UUID(), webView: WKWebView()))

        registry.updateActionColor(for: id) { $0.badgeColor = "#111111" }
        registry.updateActionColor(for: id, tab: tab.tabId) { $0.badgeColor = "#222222" }

        XCTAssertEqual(registry.extensionBridgePayloads(activeTab: tab).first?["badgeColor"] as? String, "#222222")
        XCTAssertEqual(registry.extensionBridgePayloads(activeTab: nil).first?["badgeColor"] as? String, "#111111")
    }

    func testUpdatingLastActionNotifiesExtensionSnapshotObservers() async throws {
        let extDir = try createActionExtension(named: "action_snapshot_update_extension", displayName: "Action Snapshot Update")

        try await registry.load(from: extDir)
        let loaded = try XCTUnwrap(registry.loadedExtensions.first)
        let changed = expectation(description: "onExtensionsChanged fires for an action update")
        registry.onExtensionsChanged = { changed.fulfill() }

        registry.actionDidChange(for: loaded.id)

        await fulfillment(of: [changed], timeout: 2)
    }

    func testActionChangeBumpsIconVersionInExtensionSnapshot() async throws {
        let extDir = try createActionExtension(named: "action_icon_version_extension", displayName: "Action Icon Version")

        try await registry.load(from: extDir)
        let loaded = try XCTUnwrap(registry.loadedExtensions.first)
        let initialPayload = try XCTUnwrap(registry.extensionBridgePayloads(activeTab: nil).first)

        registry.actionDidChange(for: loaded.id)
        let updatedPayload = try XCTUnwrap(registry.extensionBridgePayloads(activeTab: nil).first)

        XCTAssertEqual(initialPayload["iconVersion"] as? Int, 0)
        XCTAssertEqual(updatedPayload["iconVersion"] as? Int, 1)
    }

    /// A wrapper manifest with no recoverable metadata (`.skipped`) must still load (refusing to
    /// load would strand the user's extension) but must not silently report itself healthy either.
    func testLoadMarksExtensionDegradedWhenPreparationIsSkipped() async throws {
        let extDir = tempDir.appendingPathComponent("skipped_wrapper_extension")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Skipped Wrapper","version":"1.0","background":{"service_worker":"lilo-background-wrapper.js"}}
        """
        try manifest.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "importScripts('lilo-background-prelude.js');\nimportScripts(\"background.js\");\n"
            .write(to: extDir.appendingPathComponent("lilo-background-wrapper.js"), atomically: true, encoding: .utf8)
        // Deliberately no _lilo/metadata.json: the original entry point is unrecoverable.

        try await registry.load(from: extDir)

        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        XCTAssertEqual(registry.loadedExtensions.count, 1, "a skipped preparation must still load")
        let payload = try XCTUnwrap(extensionBridgePayload(for: id))
        XCTAssertEqual(payload["runtimeStatus"] as? String, "degraded")
    }

    /// As in Chrome, connecting to a native host that is not installed returns a port that disconnects
    /// with Chrome's message as lastError, which extensions match, and reports no extension error.
    func testMissingNativeHostDisconnectsThePortAsChromeDoes() async throws {
        let extDir = tempDir.appendingPathComponent("native_host_missing")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Native","version":"1.0","description":"d","action":{},"permissions":["nativeMessaging"],"background":{"service_worker":"background.js"}}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.connectNative('com.lilo.missing_host').onDisconnect.addListener(() => {
          chrome.action.setTitle({ title: chrome.runtime.lastError?.message ?? 'no lastError' });
        });
        """.write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))

        _ = await registry.backgrounds.load(id)
        let disconnected = await pollUntil(timeout: 10) { context.action(for: nil)?.label != "Native" }

        XCTAssertTrue(disconnected, "the port never disconnected")
        XCTAssertEqual(context.action(for: nil)?.label, "Specified native messaging host not found.")
        XCTAssertEqual(context.errors.map(\.localizedDescription), [])
    }

    /// browser.runtime.connectNative is WebKit's own: its port to a missing host disconnects once it
    /// sends, still without an extension error.
    func testMissingNativeHostThroughBrowserRuntimeDisconnectsWithoutAnError() async throws {
        let extDir = tempDir.appendingPathComponent("native_host_missing_browser")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Native","version":"1.0","description":"d","action":{},"permissions":["nativeMessaging"],"background":{"service_worker":"background.js"}}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        const port = browser.runtime.connectNative('com.lilo.missing_host');
        port.onDisconnect.addListener(() => chrome.action.setTitle({ title: 'disconnected' }));
        port.postMessage({ hello: 1 });
        """.write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))

        _ = await registry.backgrounds.load(id)
        let disconnected = await pollUntil(timeout: 10) { context.action(for: nil)?.label == "disconnected" }

        XCTAssertTrue(disconnected, "the port never disconnected")
        XCTAssertEqual(context.errors.map(\.localizedDescription), [])
    }

    func testLoadDuplicateDoesNotAddTwice() async throws {
        let extDir = try createMinimalExtension(named: "test_extension", in: tempDir)

        try await registry.load(from: extDir)
        try await registry.load(from: extDir)
        XCTAssertEqual(registry.loadedExtensions.count, 1)
    }

    func testOnExtensionsChangedFires() async throws {
        let changed = expectation(description: "onExtensionsChanged fires for a load")
        changed.assertForOverFulfill = false
        registry.onExtensionsChanged = { changed.fulfill() }

        let extDir = try createMinimalExtension(named: "test_ext3", displayName: "Test3", in: tempDir)

        try await registry.load(from: extDir)
        await fulfillment(of: [changed], timeout: 2)
    }

    func testRestoreLoadsEnabledExtensionsFromDatabase() async throws {
        let profileId = TestProfileIds.next()
        let profileDir = profileSupportDirectory(for: profileId)
        try? FileManager.default.removeItem(at: profileDir)
        defer { try? FileManager.default.removeItem(at: profileDir) }

        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        let sourceDir = try createMinimalExtension(named: "db_restore_enabled", displayName: "DB Restore Enabled", in: tempDir)
        let registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        try await registry.load(from: sourceDir)

        let restoredRegistry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        await restoredRegistry.restore()

        XCTAssertEqual(restoredRegistry.loadedExtensions.count, 1)
        XCTAssertEqual(restoredRegistry.loadedExtensions.first?.context.webExtension.displayName, "DB Restore Enabled")
    }

    func testExtensionServesItsPagesFromChromeExtensionURLs() async throws {
        let profileId = UUID()
        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        let registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        try await registry.load(from: try createMinimalExtension(named: "chrome_scheme", in: tempDir))
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)

        XCTAssertEqual(registry.context(for: id)?.baseURL.absoluteString, "chrome-extension://\(id)/")
        await registry.disable(extensionId: id)
        try await registry.enable(extensionId: id)
        XCTAssertEqual(registry.context(for: id)?.baseURL.absoluteString, "chrome-extension://\(id)/")
        let page = try XCTUnwrap(URL(string: "chrome-extension://\(id)/index.html#/onboarding"))
        XCTAssertEqual(registry.extensionNavigationTarget(for: page)?.url, page)
        XCTAssertNil(registry.extensionNavigationTarget(for: try XCTUnwrap(URL(string: "chrome-extension://other/index.html"))))
        XCTAssertNil(registry.extensionNavigationTarget(for: try XCTUnwrap(URL(string: "webkit-extension://\(id)/index.html"))))
    }

    func testExtensionInstalledDuringRestoreKeepsItsFiles() async throws {
        let restoring = Task { await registry.restore() }
        try await registry.load(from: try createMinimalExtension(named: "installed_during_restore", in: tempDir))
        await restoring.value
        let manifestPath = try XCTUnwrap(registry.loadedExtensions.first?.sourcePath) + "/manifest.json"

        // The sweep moves its orphans away before the restore returns.
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath), "the restore's sweep leaves a folder installed while it ran")
    }

    func testRestoreSkipsDisabledExtensionsFromDatabase() async throws {
        let profileId = TestProfileIds.next()
        let profileDir = profileSupportDirectory(for: profileId)
        try? FileManager.default.removeItem(at: profileDir)
        defer { try? FileManager.default.removeItem(at: profileDir) }

        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        let sourceDir = try createMinimalExtension(named: "db_restore_disabled", displayName: "DB Restore Disabled", in: tempDir)
        let registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        try await registry.load(from: sourceDir)
        let loadedId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        await registry.disable(extensionId: loadedId)
        let disabledPayload = registry.extensionBridgePayloads(activeTab: nil).first { $0["id"] as? String == loadedId }
        XCTAssertEqual(disabledPayload?["isEnabled"] as? Bool, false)
        XCTAssertEqual(disabledPayload?["name"] as? String, "DB Restore Disabled")

        let restoredRegistry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        await restoredRegistry.restore()

        XCTAssertEqual(restoredRegistry.loadedExtensions.count, 0)
        let restoredPayload = restoredRegistry.extensionBridgePayloads(activeTab: nil).first { $0["id"] as? String == loadedId }
        XCTAssertEqual(restoredPayload?["isEnabled"] as? Bool, false)
        let stored = try await storage.load(id: loadedId)
        XCTAssertFalse(stored?.isEnabled ?? true)

        try await restoredRegistry.enable(extensionId: loadedId)
        XCTAssertEqual(restoredRegistry.loadedExtensions.count, 1)
        XCTAssertEqual(restoredRegistry.extensionBridgePayloads(activeTab: nil).filter { $0["id"] as? String == loadedId }.count, 1)
    }

    func testLoadPersistsInstalledExtensionInDatabase() async throws {
        let profileId = TestProfileIds.next()
        let profileDir = profileSupportDirectory(for: profileId)
        try? FileManager.default.removeItem(at: profileDir)
        defer { try? FileManager.default.removeItem(at: profileDir) }

        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        let sourceDir = try createMinimalExtension(named: "db_install_persist", displayName: "DB Install Persist", in: tempDir)
        let registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)

        try await registry.load(from: sourceDir)

        let loadedId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let stored = try await storage.load(id: loadedId)
        XCTAssertEqual(stored?.name, "DB Install Persist")
        XCTAssertEqual(stored?.version, "1.0")
        XCTAssertEqual(stored?.path, registry.loadedExtensions.first?.sourcePath)
        XCTAssertTrue(stored?.isEnabled ?? false)
    }

    func testRestoreIgnoresExtensionFolderMissingFromDatabase() async throws {
        let profileId = TestProfileIds.next()
        let profileDir = profileSupportDirectory(for: profileId)
        try? FileManager.default.removeItem(at: profileDir)
        defer { try? FileManager.default.removeItem(at: profileDir) }

        let extensionsDir = profileDir.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        let orphanDir = extensionsDir.appendingPathComponent("orphan_extension", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Orphan Extension","version":"1.0","description":"Recovered from disk"}
        """
        try manifest.write(to: orphanDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: try makeTestExtensionStorage(profileId: profileId, in: tempDir), extensionsBaseDirectory: tempDir)
        await registry.restore()

        XCTAssertEqual(registry.loadedExtensions.count, 0)
    }

    func testTemporaryInstallReplacesExistingPermanentFolder() async throws {
        let profileId = TestProfileIds.next()
        let profileDir = profileSupportDirectory(for: profileId)
        try? FileManager.default.removeItem(at: profileDir)
        defer { try? FileManager.default.removeItem(at: profileDir) }

        let updateRegistry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: try makeTestExtensionStorage(profileId: profileId, in: tempDir), extensionsBaseDirectory: tempDir)
        let firstSource = try createMinimalExtension(named: "same_folder", displayName: "Before Update", in: tempDir)
        try await updateRegistry.load(from: firstSource)
        let id = updateRegistry.loadedExtensions.first!.id
        await updateRegistry.unload(extensionId: id)

        try FileManager.default.removeItem(at: firstSource)
        let secondSource = try createMinimalExtension(named: "same_folder", displayName: "After Update", in: tempDir)
        try await updateRegistry.load(from: secondSource)

        XCTAssertEqual(updateRegistry.loadedExtensions.first?.context.webExtension.displayName, "After Update")
    }

    // MARK: - Window Adapter Ownership

    /// A shared WindowExtensionAdapter would multiplex one WKWebExtensionWindow onto several controllers, corrupting the
    /// window/tab view and killing the service worker on a cross-profile space switch.
    func testEachRegistryOwnsADistinctWindowAdapter() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let registryA = try makeTestExtensionRegistry(in: tempDir)
        let registryB = try makeTestExtensionRegistry(in: tempDir)

        let adapterA = registryA.windowAdapter(for: window)
        let adapterB = registryB.windowAdapter(for: window)

        XCTAssertFalse(adapterA === adapterB, "Distinct registries must not share a window adapter")
        XCTAssertTrue(registryA.delegate.windowAdapter === adapterA, "Registry must wire its delegate to its own adapter")
        XCTAssertTrue(registryB.delegate.windowAdapter === adapterB)
    }

    /// Returning to a profile must reuse that registry's existing adapter, not mint a fresh one,
    /// so the controller keeps the same WKWebExtensionWindow identity across a round trip.
    func testWindowAdapterIsStableAcrossRepeatedCalls() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let adapterFirst = registry.windowAdapter(for: window)
        let adapterSecond = registry.windowAdapter(for: window)

        XCTAssertTrue(adapterFirst === adapterSecond, "Repeated calls must return the same owned adapter")
    }

    // MARK: - Permission Request Tests

    func testResolvePermissionRequest_callsHandler() {
        var called = false
        var calledGranted: Bool?
        registry.pendingPermissionRequests["test-id"] = { granted in
            called = true
            calledGranted = granted
        }
        registry.resolvePermissionRequest(id: "test-id", granted: true)
        XCTAssertTrue(called, "Completion handler should be called")
        XCTAssertEqual(calledGranted, true)
        XCTAssertNil(registry.pendingPermissionRequests["test-id"], "Handler should be removed after resolve")
    }

    func testResolvePermissionRequest_unknownIdIsNoOp() {
        // Should not crash
        registry.resolvePermissionRequest(id: "unknown-id", granted: true)
        XCTAssertTrue(true, "No crash for unknown ID")
    }

    func testHttpChromeWebStoreInstallIsRejectedBeforeNetwork() async throws {
        let handler = ExtensionUIBridgeHandler(extensionRegistryProvider: { nil })
        let message = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "installExtension",
            "payload": ["path": "http://chromewebstore.google.com/detail/name/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
        ]))

        let result = await handler.handle(message: message)

        XCTAssertEqual((result as? BridgeError)?.message, "Chrome Web Store installs require HTTPS")
    }

    func testPopupAnchorRectParsesBridgeCoordinates() throws {
        let message = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "updateExtensionPopupAnchor",
            "payload": ["id": "ext", "x": 12, "y": 708, "width": 28, "height": 28]
        ]))

        XCTAssertEqual(
            ExtensionUIBridgeHandler.anchorRect(from: message),
            NSRect(x: 12, y: 708, width: 28, height: 28)
        )
    }

    func testPopupAnchorRectIsNilWithoutCoordinates() throws {
        // chrome.action.openPopup() sends only the extension id; a fabricated
        // zero rect here would pin the popup to the window's top-left corner.
        let message = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "action.openPopup",
            "payload": ["id": "ext"]
        ]))

        XCTAssertNil(ExtensionUIBridgeHandler.anchorRect(from: message))
    }

    /// Okta Browser Plugin declares `https://*/`: Chrome grants every page of every host at install.
    func testHostPermissionsReachEveryPathOfTheirHosts() async throws {
        let extDir = tempDir.appendingPathComponent("host_paths")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Hosts","version":"1","permissions":["webNavigation"],"host_permissions":["https://*/","https://app.example.org/home"]}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try await registry.load(from: extDir)

        let context = try XCTUnwrap(registry.context(for: try XCTUnwrap(registry.loadedExtensions.first?.id)))
        XCTAssertTrue(context.hasAccess(to: try XCTUnwrap(URL(string: "https://claude.ai/oauth/authorize?client_id=x&state=y"))))
        XCTAssertTrue(context.hasAccess(to: try XCTUnwrap(URL(string: "https://app.example.org/settings"))))
        XCTAssertFalse(context.hasAccess(to: try XCTUnwrap(URL(string: "http://claude.ai/"))))
    }

    func testExtensionInstallReviewSummarizesManifestPermissions() throws {
        let extDir = tempDir.appendingPathComponent("review_extension")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Review Me","version":"2.0","permissions":["tabs","storage"],"host_permissions":["https://example.com/*"],
         "externally_connectable":{"matches":["https://app.example.org/*"]}}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let review = try ExtensionInstallReview.load(from: extDir)

        XCTAssertEqual(review.name, "Review Me")
        XCTAssertEqual(review.version, "2.0")
        XCTAssertEqual(review.permissions, ["tabs", "storage"])
        XCTAssertEqual(review.hostPermissions, ["https://example.com/*", "https://app.example.org/*"],
                       "externally_connectable matches are granted at load, so the review lists them")
        // The consent message renders human-readable warnings (Chrome-style) rather than raw tokens:
        // "tabs" becomes an "open tabs" sentence, and the host pattern its display host.
        XCTAssertTrue(review.message.contains("See the list and content of your open tabs".localized))
        XCTAssertTrue(review.message.contains("example.com"))
    }

    func testExtensionInstallReviewShowsContentScriptHostsAndUnknownPermissions() throws {
        let extDir = tempDir.appendingPathComponent("review_content")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Line\\nBreak","version":"1","permissions":["storage","fancyNewApi"],
         "content_scripts":[{"matches":["https://example.org/*"],"js":["c.js"]}]}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let review = try ExtensionInstallReview.load(from: extDir)

        XCTAssertEqual(review.name, "Line Break")
        XCTAssertEqual(review.hostPermissions, ["https://example.org/*"])
        XCTAssertTrue(review.message.contains("example.org"))
        XCTAssertTrue(review.message.contains("fancyNewApi"), "an unknown permission still gets a line")
        XCTAssertFalse(review.message.contains("storage"), "a permission Chrome installs silently gets none")
    }

    func testLocalizedNameIgnoresATraversingDefaultLocale() throws {
        let dir = tempDir.appendingPathComponent("locale_traversal")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("_locales"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("x"), withIntermediateDirectories: true)
        try #"{"appName":{"message":"Leaked"}}"#.write(to: dir.appendingPathComponent("x/messages.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ExtensionInstallReview.resolveLocalizedMessage("__MSG_appName__", defaultLocale: "../x", extensionURL: dir), "__MSG_appName__")
    }

    func testExtensionInstallReviewFlagsBroadHostAccess() {
        let broad = ExtensionInstallReview.humanReadableWarnings(
            permissions: ["history"], hostPermissions: ["<all_urls>"]
        )
        XCTAssertTrue(broad.contains("Read and change all your data on all websites you visit".localized))
        XCTAssertTrue(broad.contains("Read and erase your browsing history".localized))

        let none = ExtensionInstallReview.humanReadableWarnings(permissions: [], hostPermissions: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testInstallExtensionCanBeDeniedByReview() async throws {
        let extDir = try createMinimalExtension(named: "denied_extension", displayName: "Denied", in: tempDir)
        let handler = ExtensionUIBridgeHandler(extensionRegistryProvider: { self.registry })
        handler.installReviewHandler = { review in
            XCTAssertEqual(review.name, "Denied")
            return false
        }
        let message = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "installExtension",
            "payload": ["path": extDir.path]
        ]))

        let result = await handler.handle(message: message)

        XCTAssertEqual((result as? BridgeError)?.message, "Extension install cancelled")
        XCTAssertEqual(registry.loadedExtensions.count, 0)
    }

    func testZipSafetyRejectsParentDirectoryEntries() {
        XCTAssertFalse(ExtensionArchiveSafety.isSafeZipEntry("../manifest.json"))
        XCTAssertFalse(ExtensionArchiveSafety.isSafeZipEntry("dir/../../manifest.json"))
    }

    func testZipSafetyAllowsNormalRelativeEntries() {
        XCTAssertTrue(ExtensionArchiveSafety.isSafeZipEntry("manifest.json"))
        XCTAssertTrue(ExtensionArchiveSafety.isSafeZipEntry("icons/icon-128.png"))
    }

    func testChromeExtensionIdUsesChromeAlphabet() {
        let publicKey = Data(repeating: 0, count: 32)

        let id = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: publicKey)

        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { ("a"..."p").contains(String($0)) })
    }

    private func webExtension(manifest: String, named name: String) async throws -> WKWebExtension {
        let dir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return try await WKWebExtension(resourceBaseURL: dir)
    }

    func testAddedAccessFlagsOnlyNewGrants() async throws {
        let old = try await webExtension(manifest: """
        {"manifest_version":3,"name":"Old","version":"1","permissions":["storage","tabs"],"host_permissions":["https://example.com/*"]}
        """, named: "access_old")
        let same = try await webExtension(manifest: """
        {"manifest_version":3,"name":"Same","version":"2","permissions":["tabs","storage"],"host_permissions":["https://example.com/*"]}
        """, named: "access_same")
        let widened = try await webExtension(manifest: """
        {"manifest_version":3,"name":"Wide","version":"2","permissions":["storage","cookies"],"host_permissions":["https://example.com/*"],
         "content_scripts":[{"matches":["https://example.org/*"],"js":["c.js"]}],"optional_host_permissions":["https://example.net/*"]}
        """, named: "access_wide")

        let none = ExtensionAccess.addedAccess(from: old, to: same)
        XCTAssertTrue(none.permissions.isEmpty)
        XCTAssertTrue(none.matchPatterns.isEmpty)

        let added = ExtensionAccess.addedAccess(from: old, to: widened)
        XCTAssertEqual(added.permissions, ["cookies"], "a removed permission is not an addition")
        XCTAssertEqual(added.matchPatterns.count, 1, "a content-script host is granted, an optional host is not")
        XCTAssertTrue(added.matchPatterns.first?.contains("example.org") ?? false)

        let broad = try await webExtension(manifest: """
        {"manifest_version":3,"name":"Broad","version":"1","host_permissions":["<all_urls>"]}
        """, named: "access_broad")
        XCTAssertTrue(ExtensionAccess.addedAccess(from: broad, to: widened).matchPatterns.isEmpty,
                      "a host an old pattern already covers adds nothing")
    }

    // MARK: - Grants

    func testContentScriptHostsAreGrantedAndTheStoreIsDenied() async throws {
        let extDir = try createContentScriptExtension(named: "content_grants")
        try await registry.load(from: extDir)
        let context = try XCTUnwrap(registry.loadedExtensions.first?.context)

        XCTAssertEqual(context.permissionStatus(for: URL(string: "https://example.com/page")!), .grantedExplicitly)
        XCTAssertTrue(context.deniedPermissionMatchPatterns.keys.contains { $0.matches(URL(string: "https://chromewebstore.google.com/detail/x")) })
    }

    func testOptionalGrantsSurviveARestore() async throws {
        let profileId = TestProfileIds.next()
        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        let extDir = tempDir.appendingPathComponent("optional_grants")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Optional","version":"1","optional_permissions":["tabs"],"optional_host_permissions":["https://example.org/*"]}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let first = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        try await first.load(from: extDir)
        let context = try XCTUnwrap(first.loadedExtensions.first?.context)
        XCTAssertFalse(context.hasPermission(.tabs), "an optional permission waits for permissions.request")
        let optionalHost = try XCTUnwrap(context.webExtension.optionalPermissionMatchPatterns.first)
        XCTAssertNotEqual(context.permissionStatus(for: optionalHost), .grantedExplicitly)

        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        context.setPermissionStatus(.grantedExplicitly, for: optionalHost)
        let saved = await pollUntil { (try? await storage.loadAccessStates())?.values.first?.optionalMatchPatterns.isEmpty == false }
        XCTAssertTrue(saved)
        first.teardown()

        let restored = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        await restored.restore()
        let restoredContext = try XCTUnwrap(restored.loadedExtensions.first?.context)
        XCTAssertTrue(restoredContext.hasPermission(.tabs))
        XCTAssertEqual(restoredContext.permissionStatus(for: URL(string: "https://example.org/x")!), .grantedExplicitly)
    }

    // MARK: - Extension ids

    func testUnpackedExtensionWithAKeyTakesTheChromeId() async throws {
        let key = Data((0..<64).map { UInt8($0) })
        let extDir = tempDir.appendingPathComponent("keyed_extension")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Keyed","version":"1","key":"\(key.base64EncodedString())"}
        """.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try await registry.load(from: extDir)

        XCTAssertEqual(registry.loadedExtensions.first?.id, ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key))
    }

    func testOnlyTheManagedDirectoryLendsAFolderNameId() {
        let storeId = String(repeating: "a", count: 32)
        let managed = tempDir.appendingPathComponent("Managed", isDirectory: true)
        XCTAssertEqual(
            ExtensionFiles.makeExtensionId(for: managed.appendingPathComponent(storeId), managedDirectory: managed, manifestKey: nil),
            storeId
        )
        let unpacked = ExtensionFiles.makeExtensionId(
            for: tempDir.appendingPathComponent("Downloads/\(storeId)"), managedDirectory: managed, manifestKey: nil
        )
        XCTAssertTrue(unpacked.hasPrefix("extension-"), "an unpacked folder named like a store id must not take that id")
    }

    // MARK: - Failed restore

    func testFailedRestoreKeepsARowWithTheError() async throws {
        let profileId = TestProfileIds.next()
        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        try await storage.store(id: "extension-missing", name: "Gone", version: "1", path: tempDir.appendingPathComponent("gone").path, enabled: true)

        let registry = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        await registry.restore()

        let row = try XCTUnwrap(registry.extensionBridgePayloads(activeTab: nil).first { $0["id"] as? String == "extension-missing" })
        XCTAssertEqual(row["runtimeStatus"] as? String, "failed")
        XCTAssertFalse((row["error"] as? String ?? "").isEmpty)
        let stored = try await storage.load(id: "extension-missing")
        XCTAssertTrue(stored?.isEnabled ?? false, "the record stays enabled so the next launch retries")
    }

    func testUninstallOfADisabledExtensionRemovesItsRecord() async throws {
        let extDir = try createMinimalExtension(named: "disabled_uninstall", in: tempDir)
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        await registry.disable(extensionId: id)

        await registry.unload(extensionId: id)

        XCTAssertFalse(registry.extensionBridgePayloads(activeTab: nil).contains { $0["id"] as? String == id })
    }

    func testADisabledExtensionKeepsItsManifestIcon() async throws {
        let extDir = tempDir.appendingPathComponent("disabled_icon")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Icon", "version": "1.0", "icons": ["16": "small.png", "32": "middle.png", "128": "large.png"]])
            .write(to: extDir.appendingPathComponent("manifest.json"))
        try Data("small".utf8).write(to: extDir.appendingPathComponent("small.png"))
        try Data("middle".utf8).write(to: extDir.appendingPathComponent("middle.png"))
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)

        await registry.disable(extensionId: id)

        let payload = try XCTUnwrap(registry.extensionBridgePayloads(activeTab: nil).first { $0["id"] as? String == id })
        XCTAssertEqual(payload["iconDataURL"] as? String, "data:image/png;base64,\(Data("middle".utf8).base64EncodedString())")
    }

    func testManagementSetEnabledDisablesAndReenablesThroughRegistry() async throws {
        let extDir = try createMinimalExtension(named: "toggle_extension", displayName: "Toggle", in: tempDir)
        try await registry.load(from: extDir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)

        let handler = ManagementBridgeHandler()

        let disableMsg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "management.setEnabled",
            "payload": ["id": id, "enabled": false]
        ]))
        let disableResult = await handler.handle(disableMsg, registry: registry)
        XCTAssertNil(disableResult)
        XCTAssertFalse(registry.loadedExtensions.contains { $0.id == id })

        let enableMsg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "management.setEnabled",
            "payload": ["id": id, "enabled": true]
        ]))
        let enableResult = await handler.handle(enableMsg, registry: registry)
        XCTAssertNil(enableResult)
        XCTAssertTrue(registry.loadedExtensions.contains { $0.id == id })
    }

    // MARK: - Private spaces

    func testPrivateAccessAppliesLiveAndSurvivesARestore() async throws {
        let profileId = TestProfileIds.next()
        let storage = try makeTestExtensionStorage(profileId: profileId, in: tempDir)
        let first = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        try await first.load(from: try createMinimalExtension(named: "private_access", in: tempDir))
        let id = try XCTUnwrap(first.loadedExtensions.first?.id)
        XCTAssertFalse(try XCTUnwrap(first.context(for: id)).hasAccessToPrivateData, "private spaces stay off until allowed")

        await first.access.setPrivateAccess(extensionId: id, allowed: true)

        XCTAssertTrue(try XCTUnwrap(first.context(for: id)).hasAccessToPrivateData)
        XCTAssertEqual(first.extensionBridgePayloads(activeTab: nil).first?["allowsPrivateAccess"] as? Bool, true)
        first.teardown()
        let restored = ProfileExtensionRegistry(profileId: profileId, extensionStorage: storage, extensionsBaseDirectory: tempDir)
        await restored.restore()
        XCTAssertTrue(try XCTUnwrap(restored.context(for: id)).hasAccessToPrivateData)
    }

    // MARK: - Site access

    func testSiteAccessUnrestrictedKeepsTheManifestPatterns() throws {
        let requested: Set<WKWebExtension.MatchPattern> = [try XCTUnwrap(WKWebExtension.MatchPattern(string: "*://*/*"))]

        let granted = ExtensionAccess.grantedMatchPatterns(requested: requested, allowedHosts: [])

        XCTAssertEqual(granted, requested)
    }

    func testSiteAccessNarrowsToTheAllowedHosts() throws {
        let requested: Set<WKWebExtension.MatchPattern> = [try XCTUnwrap(WKWebExtension.MatchPattern(string: "*://*/*"))]

        let granted = ExtensionAccess.grantedMatchPatterns(requested: requested, allowedHosts: ["example.com"])

        XCTAssertEqual(granted.count, 1)
        XCTAssertTrue(granted.contains { $0.matches(URL(string: "https://www.example.com/cart")) })
        XCTAssertFalse(granted.contains { $0.matches(URL(string: "https://www.example.org/")) })
    }

    func testSiteAccessCannotWidenPastTheManifest() throws {
        let requested: Set<WKWebExtension.MatchPattern> = [try XCTUnwrap(WKWebExtension.MatchPattern(string: "*://*.example.com/*"))]

        let granted = ExtensionAccess.grantedMatchPatterns(requested: requested, allowedHosts: ["example.org"])

        XCTAssertTrue(granted.isEmpty, "a host the manifest never asked for must not become a grant")
    }

    func testSiteAccessHostsAreNormalized() {
        let hosts = ExtensionAccess.normalizedHosts([
            "  https://WWW.Example.com/gp/cart?x=1  ", "example.com", "example.org", "localhost", "", ".com"
        ])

        XCTAssertEqual(hosts, ["example.com", "example.org"])
    }
}
