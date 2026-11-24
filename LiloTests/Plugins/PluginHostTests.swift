import XCTest
@testable import Lilo
import PluginCore
import TestingSupport

@MainActor
final class PluginHostTests: XCTestCase {
    private var root: URL!
    private var database: TemporaryProfileDatabase?
    /// `PluginHost`'s reference is `weak` (the app's store lives on the context); tests retain it here.
    private var store: SettingsStore?
    private var userRoot: URL { root.appendingPathComponent("user", isDirectory: true) }
    private var bundledRoot: URL { root.appendingPathComponent("bundled", isDirectory: true) }
    private var supportRoot: URL { root.appendingPathComponent("support", isDirectory: true) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-plugin-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        store = nil
        database = nil
        super.tearDown()
    }

    private func makeHost(
        scheduler: any PluginScheduler = RecordingPluginScheduler()
    ) throws -> (PluginHost, SettingsStore, InMemoryPluginSecretStore) {
        let database = try TemporaryProfileDatabase(schema: .global)
        self.database = database
        let store = SettingsStore(dbPool: database.pool)
        self.store = store
        let secrets = InMemoryPluginSecretStore()
        let host = PluginHost(
            settingsStore: store,
            registry: PluginRegistry(userRoot: userRoot, bundledRoot: bundledRoot, supportRoot: supportRoot),
            secrets: secrets,
            makeScheduler: { _ in scheduler }
        )
        return (host, store, secrets)
    }

    func testRefreshBuildsRowsForValidAndRejectedPlugins() async throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub"), manifest: [
            "contributes": ["settings": [
                ["name": "mode", "type": "dropdown", "title": "Mode", "options": ["a", "b"], "default": "a"]
            ]]
        ])
        let bad = bundledRoot.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try "{".write(to: bad.appendingPathComponent("lilo-plugin.json"), atomically: true, encoding: .utf8)

        let (host, _, _) = try makeHost()
        await host.refresh()
        let rows = await host.pluginRows()
        XCTAssertEqual(rows.count, 2)

        let stub = try XCTUnwrap(rows.first { $0["id"] as? String == "app.lilo.test.stub" })
        XCTAssertEqual(stub["title"] as? String, "Stub Plugin")
        XCTAssertEqual(stub["enabled"] as? Bool, false)
        XCTAssertEqual(stub["running"] as? Bool, false)
        XCTAssertEqual(stub["capabilities"] as? [String], ["settings:store"])
        XCTAssertEqual(stub["grantedCapabilities"] as? [String], ["settings:store"])
        XCTAssertEqual(stub["supportDir"] as? String, supportRoot.appendingPathComponent("app.lilo.test.stub").path)
        XCTAssertNil(stub["rejectionReason"])
        let specs = try XCTUnwrap(stub["settings"] as? [[String: Any]])
        XCTAssertEqual(specs.first?["type"] as? String, "dropdown")
        XCTAssertEqual(specs.first?["options"] as? [String], ["a", "b"])
        // Unset non-password settings report nothing; defaults come from the spec.
        XCTAssertEqual((stub["settingValues"] as? [String: Any])?.isEmpty, true)

        let rejected = try XCTUnwrap(rows.first { $0["id"] as? String == "bad" })
        XCTAssertNotNil(rejected["rejectionReason"])
        XCTAssertEqual(rejected["capabilities"] as? [String], [])
    }

    func testEnableAndGrantsPersistThroughTheSettingsStore() async throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub"), manifest: [
            "capabilities": ["settings:store", "tabs:read"]
        ])
        let (host, store, _) = try makeHost()
        await host.refresh()

        host.setEnabled(true, for: "app.lilo.test.stub")
        XCTAssertEqual(store.enabledPluginIDs, ["app.lilo.test.stub"])

        // Revoking persists the smaller grant set; the declared capabilities stay listed.
        host.revokeCapability("tabs:read", for: "app.lilo.test.stub")
        XCTAssertEqual(store.pluginCapabilityGrants["app.lilo.test.stub"], ["settings:store"])
        let rows = await host.pluginRows()
        let stub = try XCTUnwrap(rows.first)
        XCTAssertEqual(stub["grantedCapabilities"] as? [String], ["settings:store"])
        XCTAssertEqual(stub["capabilities"] as? [String], ["settings:store", "tabs:read"])

        // A second host on the same store sees the persisted state.
        let (other, _, _) = {
            let secrets = InMemoryPluginSecretStore()
            let host = PluginHost(
                settingsStore: store,
                registry: PluginRegistry(userRoot: userRoot, bundledRoot: bundledRoot, supportRoot: supportRoot),
                secrets: secrets
            )
            return (host, store, secrets)
        }()
        await other.refresh()
        let otherRows = await other.pluginRows()
        XCTAssertEqual(otherRows.first?["enabled"] as? Bool, true)
        XCTAssertEqual(otherRows.first?["grantedCapabilities"] as? [String], ["settings:store"])
    }

    func testSettingValuesPersistAndPasswordsGoToSecrets() async throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub"), manifest: [
            "contributes": ["settings": [
                ["name": "mode", "type": "text", "title": "Mode"],
                ["name": "apiKey", "type": "password", "title": "API key"]
            ]]
        ])
        let (host, store, secrets) = try makeHost()
        await host.refresh()

        host.setSetting(name: "mode", value: .string("fast"), for: "app.lilo.test.stub")
        XCTAssertEqual(store.pluginSettingValues["app.lilo.test.stub"]?["mode"], .string("fast"))

        // Password settings land in the secret store, never the settings table.
        host.setSetting(name: "apiKey", value: .string("s3cret"), for: "app.lilo.test.stub")
        XCTAssertNil(store.pluginSettingValues["app.lilo.test.stub"]?["apiKey"])
        XCTAssertEqual(try secrets.secret(for: "app.lilo.test.stub", name: "apiKey"), "s3cret")

        let rows = await host.pluginRows()
        let values = try XCTUnwrap(rows.first?["settingValues"] as? [String: Any])
        XCTAssertEqual(values["mode"] as? String, "fast")
        // The panel sees only that a secret exists.
        XCTAssertEqual(values["apiKey"] as? String, "********")
    }

    func testSessionIsCreatedOnlyForEnabledValidPlugins() async throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub"))
        let (host, _, _) = try makeHost()
        await host.refresh()

        // Disabled: no session.
        let missing = await host.session(for: "app.lilo.test.stub")
        XCTAssertNil(missing)

        host.setEnabled(true, for: "app.lilo.test.stub")
        let session = await host.session(for: "app.lilo.test.stub")
        XCTAssertNotNil(session)
        // Lazy: the session object is not a process.
        let running = await session?.isRunning ?? true
        XCTAssertFalse(running)

        host.setEnabled(false, for: "app.lilo.test.stub")
        let dropped = await host.session(for: "app.lilo.test.stub")
        XCTAssertNil(dropped)
    }

    func testRefreshDropsSessionWhoseFolderChanged() async throws {
        let folder = userRoot.appendingPathComponent("stub")
        try StubPlugin.write(at: folder)
        let (host, _, _) = try makeHost()
        await host.refresh()
        host.setEnabled(true, for: "app.lilo.test.stub")
        let first = await host.session(for: "app.lilo.test.stub")

        // Rewrite the manifest: the session for the old manifest drops on the next rescan.
        try StubPlugin.write(at: folder, manifest: ["version": "2.0.0"])
        await host.refresh()
        let second = await host.session(for: "app.lilo.test.stub")
        XCTAssertNotNil(second)
        XCTAssertTrue(first !== second)
    }

    func testHostAPIGatesOnLiveGrantsAndRoutesSettingsAndFiles() async throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub"), manifest: [
            "capabilities": ["settings:store", "files:plugin-dir", "tabs:read", "tabs:open"]
        ])
        let (host, store, _) = try makeHost()
        await host.refresh()
        let record = try XCTUnwrap(host.record(id: "app.lilo.test.stub"))
        let api = host.hostAPI(for: record)

        let set = await api.handle("settings.set", params: .object(["name": .string("mode"), "value": .string("fast")]))
        XCTAssertEqual(set, .success(.null))
        XCTAssertEqual(store.pluginSettingValues["app.lilo.test.stub"]?["mode"], .string("fast"))

        // Files land in the plugin's support folder, nowhere else.
        let write = await api.handle("files.write", params: .object(["path": .string("state.json"), "content": .string("{}")]))
        XCTAssertEqual(write, .success(.null))
        XCTAssertEqual(
            try String(contentsOf: supportRoot.appendingPathComponent("app.lilo.test.stub/state.json"), encoding: .utf8), "{}"
        )

        // With no window the tab adapter answers an empty list and cannot open.
        let list = await api.handle("tabs.list", params: .null)
        XCTAssertEqual(list, .success(.object(["tabs": .array([])])))
        let open = await api.handle("tabs.open", params: .object(["url": .string("https://example.com")]))
        XCTAssertEqual(open, .failure(PluginRequestError(code: -32002, message: "No window can open the tab")))

        // A revoke applies to the api already handed to a running session.
        host.revokeCapability("tabs:read", for: "app.lilo.test.stub")
        host.revokeCapability("files:plugin-dir", for: "app.lilo.test.stub")
        let revokedTabs = await api.handle("tabs.list", params: .null)
        XCTAssertEqual(revokedTabs, .failure(.capabilityNotGranted))
        let revokedFiles = await api.handle("files.read", params: .object(["path": .string("state.json")]))
        XCTAssertEqual(revokedFiles, .failure(.capabilityNotGranted))
        let settings = await api.handle("settings.get", params: .null)
        XCTAssertEqual(settings, .success(.object(["mode": .string("fast")])))
    }

    func testTabAdapterMapsATabToIDURLAndTitle() {
        let tab = Tab(id: UUID(), url: URL(string: "https://example.com/a"), title: "Example")
        XCTAssertEqual(
            PluginTabsAdapter.plugin(tab),
            PluginTab(id: tab.id.uuidString, url: "https://example.com/a", title: "Example")
        )
        XCTAssertEqual(PluginTabsAdapter.plugin(Tab(url: nil, title: "")).url, "")
    }

    // MARK: - schedule capability

    private func scheduledStub(capabilities: [String] = ["settings:store", "schedule"]) throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub"), manifest: ["capabilities": capabilities])
    }

    private func api(for host: PluginHost, id: String = "app.lilo.test.stub") throws -> PluginHostAPI {
        try host.hostAPI(for: XCTUnwrap(host.record(id: id)))
    }

    func testScheduleRequestsReachTheSchedulerOnlyWithTheGrant() async throws {
        try scheduledStub()
        let scheduler = RecordingPluginScheduler()
        let (host, _, _) = try makeHost(scheduler: scheduler)
        await host.refresh()
        host.setEnabled(true, for: "app.lilo.test.stub")
        await host.refresh()
        let api = try api(for: host)

        let set = await api.handle("schedule.set", params: .object(["id": .string("job"), "delay": .number(90)]))
        XCTAssertEqual(set, .success(.null))
        XCTAssertEqual(scheduler.delays["job"], 90)

        let cancel = await api.handle("schedule.cancel", params: .object(["id": .string("job")]))
        XCTAssertEqual(cancel, .success(.null))
        XCTAssertEqual(scheduler.cancelled, ["job"])

        host.revokeCapability("schedule", for: "app.lilo.test.stub")
        let denied = await api.handle("schedule.set", params: .object(["id": .string("x"), "delay": .number(1)]))
        XCTAssertEqual(denied, .failure(.capabilityNotGranted))
        XCTAssertNil(scheduler.delays["x"])
    }

    func testUnknownMethodsAnswerMethodNotFound() async throws {
        try scheduledStub(capabilities: ["tabs:open"])
        let (host, _, _) = try makeHost()
        await host.refresh()
        host.setEnabled(true, for: "app.lilo.test.stub")
        let api = try api(for: host)

        let unknown = await api.handle("tabs.close", params: .object([:]))
        XCTAssertEqual(unknown, .failure(.methodNotFound))

        host.revokeCapability("tabs:open", for: "app.lilo.test.stub")
        let denied = await api.handle("tabs.open", params: .object(["url": .string("https://example.com")]))
        XCTAssertEqual(denied, .failure(.capabilityNotGranted))
    }

    func testAFireWakesTheSleepingSidecar() async throws {
        try scheduledStub()
        let scheduler = RecordingPluginScheduler()
        let (host, _, _) = try makeHost(scheduler: scheduler)
        await host.refresh()
        host.setEnabled(true, for: "app.lilo.test.stub")
        _ = await api(for: host).handle("schedule.set", params: .object(["id": .string("job"), "delay": .number(5)]))
        let sessionOrNil = await host.session(for: "app.lilo.test.stub")
        let session = try XCTUnwrap(sessionOrNil)
        await session.stop()

        scheduler.fire("job")
        var running = false
        for _ in 0..<100 {
            running = await session.isRunning
            if running { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(running)
        await session.stop()
    }
}
