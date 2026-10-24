import WebKit
import XCTest
@testable import Lilo

/// The chrome.runtime, management, downloads and action members and the worker WebSockets Lilo adds,
/// through the real gap router and the profile registry of a bootstrapped browser context.
@MainActor
final class RuntimeGapAPITests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var registry: ProfileExtensionRegistry!
    private var router: GapBridgeRouter!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        registry = try context.profileContexts.context(for: profileId).extensions
        router = context.engineFactory.gapRouter
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-gap-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        registry = nil
        router = nil
        browserContext.tearDown()
        browserContext = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// Loads an unpacked extension declaring `permissions` and returns its id.
    private func loadExtension(_ name: String, permissions: [String] = []) async throws -> String {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": name, "version": "1.0", "permissions": permissions]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let before = Set(registry.loadedExtensions.map(\.id))
        try await registry.load(from: folder)
        return try XCTUnwrap(registry.loadedExtensions.map(\.id).first { !before.contains($0) })
    }

    private func call(_ namespace: String, _ method: String, _ params: [String: Any] = [:], from extensionId: String) async -> (result: Any?, error: String?) {
        await router.route(namespace: namespace, method: method, params: params, extensionId: extensionId, fromWorker: true, registry: registry)
    }

    private func queued(_ name: String, for extensionId: String) -> [GapEventEnvelope] {
        registry.gapEvents.undelivered(to: extensionId).filter { "\($0.namespace).\($0.event)" == name }
    }

    // MARK: - webSocket

    func testAWebSocketServesOnlyTheExtensionThatOpenedIt() async throws {
        let owner = try await loadExtension("owner")
        let other = try await loadExtension("other")
        // A non-routable address: the socket stays connecting for the whole test.
        let opened = await call("webSocket", "connect", ["url": "ws://10.255.255.1/"], from: owner)
        let id = try XCTUnwrap(opened.result as? Int, opened.error ?? "")

        let fromOther = await call("webSocket", "send", ["id": id, "text": "hi"], from: other)

        XCTAssertEqual(fromOther.error, "WebSocket is closed")
        _ = await call("webSocket", "close", ["id": id], from: owner)
    }

    // MARK: - runtime events

    func testAnInstallTellsTheExtensionItLoaded() async throws {
        let id = try await loadExtension("installed")

        let loaded = queued("runtime.onExtensionLoaded", for: id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.args.first as? [String: String], ["reason": "install"])
        XCTAssertTrue(queued("runtime.onEnabled", for: id).isEmpty)
    }

    func testEnablingSendsOnEnabledThenOnExtensionLoaded() async throws {
        let id = try await loadExtension("enabled")
        await registry.disable(extensionId: id)
        try await registry.enable(extensionId: id)

        let events = registry.gapEvents.undelivered(to: id).map { "\($0.namespace).\($0.event)" }
        XCTAssertEqual(events, ["runtime.onEnabled", "runtime.onExtensionLoaded"])
        XCTAssertEqual(queued("runtime.onExtensionLoaded", for: id).first?.args.first as? [String: String], ["reason": "enable"])
    }

    func testAWorkersListenersOutliveItsUnload() async throws {
        let id = try await loadExtension("listening")
        await registry.addGapListeners(["runtime.onExtensionLoaded"], extensionId: id, fromWorker: true)
        await registry.disable(extensionId: id)
        try await registry.enable(extensionId: id)

        XCTAssertEqual(registry.gapEvents.reportedListeners(of: id), ["runtime.onExtensionLoaded"])
        XCTAssertEqual(registry.listeningExtensionIds("windows", "onBoundsChanged"), [], "an event it never listened to does not wake it")
        XCTAssertEqual(queued("runtime.onExtensionLoaded", for: id).count, 1)
        XCTAssertTrue(queued("runtime.onEnabled", for: id).isEmpty, "filtered: the worker does not listen to it")
    }

    func testALaunchTellsOnlyWorkersKnownToListen() async throws {
        let listening = try await loadExtension("listener")
        let silent = try await loadExtension("silent")
        await registry.addGapListeners(["runtime.onExtensionLoaded"], extensionId: listening, fromWorker: true)

        registry.teardown()
        await registry.restore()

        XCTAssertEqual(queued("runtime.onExtensionLoaded", for: listening).last?.args.first as? [String: String], ["reason": "startup"])
        let silentReasons = queued("runtime.onExtensionLoaded", for: silent).map { ($0.args.first as? [String: String])?["reason"] }
        XCTAssertEqual(silentReasons, ["install"], "a worker never heard from is not woken at launch")
    }

    func testRequestUpdateCheckOfAnUnpackedExtensionIsThrottledAfterItsFirstCheck() async throws {
        let id = try await loadExtension("unpacked")

        let first = await call("runtime", "requestUpdateCheck", from: id)
        let second = await call("runtime", "requestUpdateCheck", from: id)
        XCTAssertEqual(first.result as? [String: String], ["status": "no_update", "version": ""])
        XCTAssertEqual(second.result as? [String: String], ["status": "throttled", "version": ""])
    }

    // MARK: - action.onUserSettingsChanged

    func testPinningAnExtensionTellsItIsOnTheToolbar() async throws {
        let pinned = try await loadExtension("pinned")
        let other = try await loadExtension("other")

        registry.pinnedExtensionsChanged(from: other, to: "\(other),\(pinned)")
        registry.pinnedExtensionsChanged(from: "\(other),\(pinned)", to: pinned)

        XCTAssertEqual(queued("action.onUserSettingsChanged", for: pinned).map { $0.args.first as? [String: Bool] }, [["isOnToolbar": true]])
        XCTAssertEqual(queued("action.onUserSettingsChanged", for: other).map { $0.args.first as? [String: Bool] }, [["isOnToolbar": false]])
    }

    // MARK: - downloads.setUiOptions

    func testDownloadUiStaysHiddenWhileAnyExtensionHidesIt() async throws {
        let first = try await loadExtension("first", permissions: ["downloads", "downloads.ui"])
        let second = try await loadExtension("second", permissions: ["downloads", "downloads.ui"])
        let undeclared = try await loadExtension("undeclared", permissions: ["downloads"])

        let refused = await call("downloads", "setUiOptions", ["enabled": false], from: undeclared)
        XCTAssertEqual(refused.error, "downloads.setUiOptions requires the \"downloads.ui\" permission")

        let hidden = await call("downloads", "setUiOptions", ["enabled": false], from: first)
        XCTAssertNil(hidden.error)
        let blocked = await call("downloads", "setUiOptions", ["enabled": true], from: second)
        XCTAssertEqual(blocked.error, "Another extension has disabled the download UI")
        XCTAssertEqual(registry.downloadUiDisabledBy, [first])

        await registry.unload(extensionId: first)
        XCTAssertTrue(registry.downloadUiDisabledBy.isEmpty, "an unloaded extension no longer hides it")
    }

    // MARK: - management app calls

    func testAppCallsFailWithChromesErrorsForANonApp() async throws {
        let manager = try await loadExtension("manager", permissions: ["management"])

        let notAnApp = await call("management", "launchApp", ["id": manager], from: manager)
        let unknown = await call("management", "launchApp", ["id": "missing"], from: manager)
        let noGesture = await call("management", "createAppShortcut", ["id": manager, "userGesture": false], from: manager)
        let launchType = await call("management", "setLaunchType", ["id": manager, "launchType": "OPEN_AS_WINDOW", "userGesture": true], from: manager)
        XCTAssertEqual(notAnApp.error, "Extension \(manager) is not an App.")
        XCTAssertEqual(unknown.error, "Failed to find extension with id missing.")
        XCTAssertEqual(noGesture.error, "chrome.management.createAppShortcut requires a user gesture.")
        XCTAssertEqual(launchType.error, "Extension \(manager) is not an App.")
    }

    func testGenerateAppForLinkChecksItsArgumentsThenFails() async throws {
        let manager = try await loadExtension("generator", permissions: ["management"])

        let badURL = await call("management", "generateAppForLink", ["url": "ftp://example.com", "title": "App", "userGesture": true], from: manager)
        let noTitle = await call("management", "generateAppForLink", ["url": "https://example.com", "title": "", "userGesture": true], from: manager)
        let valid = await call("management", "generateAppForLink", ["url": "https://example.com", "title": "App", "userGesture": true], from: manager)
        XCTAssertEqual(badURL.error, "The URL \"ftp://example.com\" is invalid.")
        XCTAssertEqual(noTitle.error, "The title can not be empty.")
        XCTAssertEqual(valid.error, "Failed to install the generated app.")
    }
}
