import XCTest
@testable import Lilo

/// Each lifecycle transition sends exactly the runtime events Chrome sends for it, once, read from
/// the events queued for a worker that has not connected.
@MainActor
final class ExtensionLifecycleTests: XCTestCase {
    private let id = "ext"
    private let profileId = UUID()
    private var database: TemporaryProfileDatabase!
    private var settings: SettingsStore!
    private var gapEvents: GapEvents!
    private var lifecycle: ExtensionLifecycle!
    private var appliedUpdates: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        database = try TemporaryProfileDatabase(schema: .global)
        settings = SettingsStore(dbPool: database.pool)
        lifecycle = makeLifecycle()
    }

    override func tearDown() async throws {
        lifecycle = nil
        gapEvents = nil
        settings = nil
        database.tearDown()
        try await super.tearDown()
    }

    /// A lifecycle over the shared settings, as a relaunch builds one.
    private func makeLifecycle() -> ExtensionLifecycle {
        var lifecycle: ExtensionLifecycle?
        let gapEvents = GapEvents(
            wake: { lifecycle?.wake($0) },
            workerChannel: { lifecycle?.workerChannel($0, $1) },
            route: { _, _, _, _, _ in (nil, nil) }
        )
        let backgrounds = BackgroundSupervisor(
            context: { _ in nil }, worker: { lifecycle?.worker(of: $0) }, ready: { gapEvents.isReady($0) }, reload: { _ in }, didChange: { _ in }
        )
        let made = ExtensionLifecycle(
            profileId: profileId, gapEvents: gapEvents, backgrounds: backgrounds,
            settings: { [unowned self] in self.settings },
            applyUpdate: { [unowned self] id, from in self.appliedUpdates.append("\(id)@\(from)") }
        )
        lifecycle = made
        self.gapEvents = gapEvents
        return made
    }

    /// Every event queued for the worker, with its first argument when it has one.
    private var heard: [String] {
        gapEvents.undelivered(to: id).map { envelope in
            let name = "\(envelope.namespace).\(envelope.event)"
            guard let details = envelope.args.first as? [String: String] else { return name }
            return name + " " + details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
    }

    private func load(_ load: ExtensionLifecycle.Load, version: String = "1.0", storedVersion: String? = "1.0", hasBackground: Bool = true) {
        lifecycle.loaded(id, load, version: version, storedVersion: storedVersion, hasBackground: hasBackground, preparationDegraded: false)
    }

    // MARK: - Loads

    func testAnInstallSendsOnInstalledAndOnExtensionLoaded() {
        load(.install, storedVersion: nil)

        XCTAssertEqual(heard, ["runtime.onInstalled reason=install", "runtime.onExtensionLoaded reason=install"])
        XCTAssertEqual(lifecycle.state(of: id), .loaded(.stopped))
    }

    func testAnInstallWithoutAWorkerOnlySendsOnExtensionLoaded() {
        load(.install, storedVersion: nil, hasBackground: false)

        XCTAssertEqual(heard, ["runtime.onExtensionLoaded reason=install"])
    }

    func testAnEnableSendsOnEnabledThenOnExtensionLoaded() {
        load(.install, storedVersion: nil)
        lifecycle.unloaded(id, disabled: true, purge: true)
        XCTAssertEqual(lifecycle.state(of: id), .disabled(updatedFrom: nil))
        XCTAssertEqual(heard, [], "a disable drops what the worker had not received")

        load(.enable)

        XCTAssertEqual(heard, ["runtime.onEnabled", "runtime.onExtensionLoaded reason=enable"])
    }

    func testAnEnableOfAChangedVersionAlsoSendsOnInstalledUpdate() {
        lifecycle.unloaded(id, disabled: true, purge: true)
        load(.enable, version: "2.0", storedVersion: "1.0")

        XCTAssertEqual(heard, [
            "runtime.onInstalled previousVersion=1.0,reason=update", "runtime.onEnabled", "runtime.onExtensionLoaded reason=enable"
        ])
    }

    func testAnUpdateSendsOnInstalledUpdateWithThePreviousVersion() {
        load(.update(from: "1.0"), version: "2.0", storedVersion: "1.0")

        XCTAssertEqual(heard, [
            "runtime.onInstalled previousVersion=1.0,reason=update", "runtime.onExtensionLoaded previousVersion=1.0,reason=update"
        ])
    }

    func testAReloadOfTheSameVersionSendsNothing() {
        load(.reload)

        XCTAssertEqual(heard, [])
    }

    func testALaunchSendsOnStartupAndOnExtensionLoadedOnlyToAWorkerKnownToListen() {
        load(.startup)
        XCTAssertEqual(heard, ["runtime.onStartup"], "a worker never heard from is not told it loaded")

        lifecycle.listen(["runtime.onStartup", "runtime.onExtensionLoaded"], extensionId: id, version: "1.0")
        lifecycle.unloaded(id, disabled: false, purge: true)
        lifecycle = makeLifecycle()
        load(.startup)

        XCTAssertEqual(heard, ["runtime.onStartup", "runtime.onExtensionLoaded reason=startup"], "its reported listeners outlive the launch")
    }

    func testAListenerTheWorkerRemovedNoLongerWakesItOnTheNextLaunch() {
        load(.startup)
        lifecycle.listen(["runtime.onStartup", "runtime.onExtensionLoaded"], extensionId: id, version: "1.0")
        lifecycle.listen(["runtime.onStartup"], extensionId: id, removed: true, version: "1.0")
        lifecycle.unloaded(id, disabled: false, purge: true)
        lifecycle = makeLifecycle()
        load(.startup)

        XCTAssertEqual(heard, ["runtime.onExtensionLoaded reason=startup"])
    }

    func testAnUpdateAppliedWhileDisabledIsReportedByTheNextLoadOnly() {
        lifecycle.unloaded(id, disabled: true, purge: true)
        lifecycle.updatedWhileDisabled(id, from: "1.0")
        lifecycle.updatedWhileDisabled(id, from: "1.1")
        XCTAssertEqual(lifecycle.state(of: id), .disabled(updatedFrom: "1.0"), "the version the extension last ran stays")

        lifecycle = makeLifecycle()
        lifecycle.restoreDisabled([id])
        load(.enable, version: "1.2", storedVersion: "1.2")
        XCTAssertEqual(heard, [
            "runtime.onInstalled previousVersion=1.0,reason=update", "runtime.onEnabled", "runtime.onExtensionLoaded reason=enable"
        ])

        lifecycle.unloaded(id, disabled: true, purge: true)
        lifecycle = makeLifecycle()
        lifecycle.restoreDisabled([id])
        XCTAssertEqual(lifecycle.state(of: id), .disabled(updatedFrom: nil))
    }

    // MARK: - Worker

    func testTheWorkerFollowsItsChannelUntilTheExtensionUnloads() {
        XCTAssertNil(lifecycle.worker(of: id))
        load(.reload)
        XCTAssertEqual(lifecycle.worker(of: id), .stopped)

        lifecycle.workerChannel(id, .open)
        XCTAssertEqual(lifecycle.worker(of: id), .running)
        lifecycle.workerChannel(id, .idle)
        XCTAssertEqual(lifecycle.worker(of: id), .idle)
        lifecycle.workerChannel(id, .open)
        lifecycle.workerChannel(id, .lost)
        XCTAssertEqual(lifecycle.worker(of: id), .stopped)

        lifecycle.unloaded(id, disabled: false, purge: false)
        lifecycle.workerChannel(id, .open)
        XCTAssertNil(lifecycle.state(of: id), "a channel never revives an unloaded extension")
    }

    func testAReloadKeepsWhatTheWorkerHadNotReceived() {
        load(.install, storedVersion: nil)
        lifecycle.unloaded(id, disabled: true, purge: false)

        XCTAssertEqual(heard, ["runtime.onInstalled reason=install", "runtime.onExtensionLoaded reason=install"])
    }

    // MARK: - Updates

    func testAnUpdateWaitsForTheRunningWorkerToStop() {
        load(.reload)
        XCTAssertFalse(lifecycle.updateFound(id, from: "1.0", to: "2.0", manifest: [:]), "a stopped worker updates at once")
        XCTAssertEqual(heard, [])

        lifecycle.workerChannel(id, .open)
        XCTAssertTrue(lifecycle.updateFound(id, from: "1.0", to: "2.0", manifest: ["version": "2.0"]))
        XCTAssertTrue(lifecycle.updateFound(id, from: "1.0", to: "2.0", manifest: ["version": "2.0"]))
        XCTAssertEqual(heard, ["runtime.onUpdateAvailable version=2.0"], "told once per version")
        XCTAssertEqual(lifecycle.state(of: id), .updating(from: "1.0", to: "2.0"))
        XCTAssertEqual(lifecycle.worker(of: id), .running)

        lifecycle.workerChannel(id, .open)
        XCTAssertEqual(appliedUpdates, [], "a worker that reconnects is still in use")
        lifecycle.workerChannel(id, .idle)
        XCTAssertEqual(appliedUpdates, ["ext@1.0"])
        XCTAssertEqual(lifecycle.state(of: id), .loaded(.idle))
    }

    func testOnlyADisableLetsAWaitingUpdateApply() {
        for (disabled, purge, applies) in [(true, true, true), (true, false, false), (false, false, false)] {
            appliedUpdates = []
            load(.reload)
            lifecycle.workerChannel(id, .open)
            _ = lifecycle.updateFound(id, from: "1.0", to: "2.0", manifest: [:])
            lifecycle.unloaded(id, disabled: disabled, purge: purge)
            XCTAssertEqual(appliedUpdates, applies ? ["ext@1.0"] : [], "disabled: \(disabled), purge: \(purge)")
        }

        load(.reload)
        lifecycle.workerChannel(id, .open)
        _ = lifecycle.updateFound(id, from: "1.0", to: "2.0", manifest: [:])
        appliedUpdates = []
        lifecycle.uninstalled(id)
        XCTAssertEqual(appliedUpdates, [], "an uninstall drops the update")
    }

    func testAnUninstallForgetsWhatTheLifecycleKept() {
        load(.reload)
        lifecycle.listen(["runtime.onStartup"], extensionId: id, version: "1.0")
        lifecycle.unloaded(id, disabled: true, purge: true)
        lifecycle.updatedWhileDisabled(id, from: "1.0")

        lifecycle.uninstalled(id)

        XCTAssertNil(lifecycle.state(of: id))
        lifecycle = makeLifecycle()
        lifecycle.restoreDisabled([id])
        load(.startup)
        XCTAssertEqual(lifecycle.state(of: id), .loaded(.stopped))
        XCTAssertEqual(heard, ["runtime.onStartup"], "neither its listeners nor its previous version remain")
    }
}
