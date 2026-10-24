import AppKit
import IOKit.pwr_mgt
import XCTest
@testable import Lilo

/// chrome.power, chrome.system.* and chrome.tts through the engine factory's gap router, as an
/// extension page or worker calls them.
@MainActor
final class DeviceGapAPITests: XCTestCase {
    private var tempDir: URL!
    private var factory: WKEngineFactory!
    private var cache: ProfileContextCache!
    private var profile: ProfileContext!
    private var router: GapBridgeRouter!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("device-gap-\(UUID().uuidString)")
        let dbManager = try DatabaseManager(appSupportDirectory: tempDir.path)
        let factory = WKEngineFactory()
        self.factory = factory
        cache = ProfileContextCache { profileId in
            try ProfileContext(profileId: profileId, dbManager: dbManager, gapRouter: factory.gapRouter)
        }
        factory.profileContexts = cache
        let profileId = TestProfileIds.next()
        cache.pinnedProfileIds = [profileId]
        profile = try cache.context(for: profileId)
        router = factory.gapRouter
    }

    override func tearDown() {
        router = nil
        profile = nil
        cache = nil
        factory = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func loadExtension(named name: String = "ext", permissions: [String]) async throws -> String {
        let dir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": name, "version": "1.0", "permissions": permissions]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let before = Set(profile.extensions.loadedExtensions.map(\.id))
        try await profile.extensions.load(from: dir)
        return try XCTUnwrap(profile.extensions.loadedExtensions.map(\.id).first { !before.contains($0) })
    }

    private func call(_ namespace: String, _ method: String, _ params: [String: Any] = [:], from extensionId: String) async -> (result: Any?, error: String?) {
        await router.route(
            namespace: namespace, method: method, params: params,
            extensionId: extensionId, fromWorker: true, registry: profile.extensions
        )
    }

    private func events(_ namespace: String, _ event: String, to extensionId: String) -> [[Any]] {
        profile.extensions.gapEvents.undelivered(to: extensionId).filter { $0.namespace == namespace && $0.event == event }.map(\.args)
    }

    // MARK: - power

    /// The assertion types Lilo holds for chrome.power.
    private func keepAwakeAssertions() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (all[NSNumber(value: getpid())] ?? [])
            .filter { $0[kIOPMAssertionNameKey as String] as? String == "Extension keep-awake request" }
            .compactMap { $0[kIOPMAssertionTypeKey as String] as? String }
    }

    func testKeepAwakeHoldsTheStrongestLevelRequestedUntilReleasedOrUnloaded() async throws {
        let first = try await loadExtension(named: "first", permissions: ["power"])
        let second = try await loadExtension(named: "second", permissions: ["power"])

        _ = await call("power", "requestKeepAwake", ["level": "system"], from: first)
        XCTAssertEqual(keepAwakeAssertions(), [kIOPMAssertionTypePreventUserIdleSystemSleep as String])
        _ = await call("power", "requestKeepAwake", ["level": "display"], from: second)
        XCTAssertEqual(keepAwakeAssertions(), [kIOPMAssertionTypePreventUserIdleDisplaySleep as String])

        await profile.extensions.unload(extensionId: second)
        XCTAssertEqual(keepAwakeAssertions(), [kIOPMAssertionTypePreventUserIdleSystemSleep as String], "an unloaded extension's request ends")
        _ = await call("power", "releaseKeepAwake", from: first)
        XCTAssertEqual(keepAwakeAssertions(), [])
    }

    func testPowerNeedsItsPermission() async throws {
        let extensionId = try await loadExtension(permissions: ["tts"])
        let (_, error) = await call("power", "requestKeepAwake", ["level": "display"], from: extensionId)
        XCTAssertEqual(error, "Permission 'power' is required for power.requestKeepAwake")
        XCTAssertEqual(keepAwakeAssertions(), [])
    }

    // MARK: - system

    func testCpuAndMemoryInfo() async throws {
        let extensionId = try await loadExtension(permissions: ["system.cpu", "system.memory"])

        let cpuResult = await call("system.cpu", "getInfo", from: extensionId).result
        let cpu = try XCTUnwrap(cpuResult as? [String: Any])
        XCTAssertEqual(cpu["numOfProcessors"] as? Int, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertTrue(["arm64", "x86_64"].contains(cpu["archName"] as? String ?? ""))
        XCTAssertFalse((cpu["modelName"] as? String ?? "").isEmpty)
        XCTAssertEqual((cpu["temperatures"] as? [Double])?.count, 0)
        let processors = try XCTUnwrap(cpu["processors"] as? [[String: Any]])
        XCTAssertEqual(processors.count, ProcessInfo.processInfo.activeProcessorCount)
        let usage = try XCTUnwrap(processors.first?["usage"] as? [String: Double])
        XCTAssertEqual(usage["total"], usage["user"]! + usage["kernel"]! + usage["idle"]!)
        XCTAssertGreaterThan(usage["total"]!, 0)

        let memoryResult = await call("system.memory", "getInfo", from: extensionId).result
        let memory = try XCTUnwrap(memoryResult as? [String: Double])
        XCTAssertEqual(memory["capacity"], Double(ProcessInfo.processInfo.physicalMemory))
        XCTAssertGreaterThan(memory["availableCapacity"]!, 0)
        XCTAssertLessThanOrEqual(memory["availableCapacity"]!, memory["capacity"]!)
    }

    func testStorageListsMountedVolumesUnderStableIds() async throws {
        let extensionId = try await loadExtension(permissions: ["system.storage"])

        let unitsResult = await call("system.storage", "getInfo", from: extensionId).result
        let units = try XCTUnwrap(unitsResult as? [[String: Any]])
        XCTAssertTrue(units.contains { $0["type"] as? String == "fixed" && ($0["capacity"] as? Double ?? 0) > 0 }, "the boot volume is listed")
        let ids = units.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(ids).count, units.count)
        let againResult = await call("system.storage", "getInfo", from: extensionId).result
        let again = try XCTUnwrap(againResult as? [[String: Any]])
        XCTAssertEqual(again.compactMap { $0["id"] as? String }, ids, "transient ids last while Lilo runs")

        let (result, error) = await call("system.storage", "ejectDevice", ["id": "unknown"], from: extensionId)
        XCTAssertNil(error)
        XCTAssertEqual(result as? String, "no_such_device")
    }

    func testDisplaysAndTheirChangeEvent() async throws {
        let extensionId = try await loadExtension(named: "display", permissions: ["system.display"])
        let unrelated = try await loadExtension(named: "unrelated", permissions: ["system.cpu"])

        let displaysResult = await call("system.display", "getInfo", from: extensionId).result
        let displays = try XCTUnwrap(displaysResult as? [[String: Any]])
        XCTAssertEqual(displays.count, NSScreen.screens.count)
        if let primary = displays.first, let screen = NSScreen.screens.first {
            XCTAssertEqual(primary["isPrimary"] as? Bool, true)
            XCTAssertEqual(primary["bounds"] as? [String: Int], ["left": 0, "top": 0, "width": Int(screen.frame.width), "height": Int(screen.frame.height)])
            XCTAssertEqual(primary["id"] as? String, (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue)
        }

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        XCTAssertEqual(events("system.display", "onDisplayChanged", to: extensionId).count, 1)
        XCTAssertEqual(events("system.display", "onDisplayChanged", to: unrelated).count, 0)
    }

    // MARK: - tts

    func testVoicesAreListedWithChromesEventTypes() async throws {
        let extensionId = try await loadExtension(permissions: ["tts"])
        let voicesResult = await call("tts", "getVoices", from: extensionId).result
        let voices = try XCTUnwrap(voicesResult as? [[String: Any]])
        try XCTSkipIf(voices.isEmpty, "no speech voices on this machine")
        XCTAssertEqual(voices.first?["eventTypes"] as? [String], ["start", "end", "word", "pause", "resume"])
        XCTAssertEqual(voices.first?["remote"] as? Bool, false)
        XCTAssertNotNil(voices.first?["lang"] as? String)
    }

    func testSpeakRejectsOptionsOutOfChromesRanges() async throws {
        let extensionId = try await loadExtension(permissions: ["tts"])
        for (options, message) in [(["rate": 20], "Invalid rate."), (["pitch": -1], "Invalid pitch."), (["volume": 2], "Invalid volume."), (["lang": "not a tag"], "Invalid lang.")] {
            let (_, error) = await call("tts", "speak", ["utterance": "Hello", "options": options], from: extensionId)
            XCTAssertEqual(error, message)
        }
        let (_, error) = await call("tts", "speak", ["utterance": String(repeating: "a", count: 32769)], from: extensionId)
        XCTAssertEqual(error, "Utterance length is too long.")
    }

    func testStopInterruptsTheCurrentUtteranceAndCancelsTheQueue() async throws {
        let speaker = try await loadExtension(named: "speaker", permissions: ["tts"])
        let other = try await loadExtension(named: "other", permissions: ["tts"])
        let quiet: [String: Any] = ["volume": 0]

        _ = await call("tts", "speak", ["utterance": "One two three four five six", "options": quiet, "srcId": 1], from: speaker)
        _ = await call("tts", "speak", ["utterance": "Seven", "options": quiet.merging(["enqueue": true]) { $1 }, "srcId": 2], from: speaker)
        let speaking = await call("tts", "isSpeaking", from: speaker).result
        XCTAssertEqual(speaking as? Bool, true)

        _ = await call("tts", "stop", from: other)
        let stillSpeaking = await call("tts", "isSpeaking", from: speaker).result
        XCTAssertEqual(stillSpeaking as? Bool, true, "another extension's stop leaves this speech")

        _ = await call("tts", "stop", from: speaker)
        let final = events("tts", "onEvent", to: speaker).compactMap { $0.first as? [String: Any] }.filter { $0["isFinalEvent"] as? Bool == true }
        XCTAssertEqual(final.map { $0["type"] as? String }, ["interrupted", "cancelled"])
        XCTAssertEqual(final.map { $0["srcId"] as? Int }, [1, 2])
        XCTAssertEqual(events("tts", "onEvent", to: other).count, 0)
        let stopped = await pollUntil { await self.call("tts", "isSpeaking", from: speaker).result as? Bool == false }
        XCTAssertTrue(stopped)
    }

    func testSpeakingAgainInterruptsUnlessEnqueued() async throws {
        let extensionId = try await loadExtension(permissions: ["tts"])
        let quiet: [String: Any] = ["volume": 0]

        _ = await call("tts", "speak", ["utterance": "First sentence to say", "options": quiet, "srcId": 1], from: extensionId)
        _ = await call("tts", "speak", ["utterance": "Second", "options": quiet.merging(["desiredEventTypes": ["end"]]) { $1 }, "srcId": 2], from: extensionId)
        _ = await call("tts", "stop", from: extensionId)

        let sent = events("tts", "onEvent", to: extensionId).compactMap { $0.first as? [String: Any] }
        XCTAssertTrue(sent.contains { $0["srcId"] as? Int == 1 && $0["type"] as? String == "interrupted" })
        XCTAssertFalse(sent.contains { $0["srcId"] as? Int == 2 }, "desiredEventTypes filters the second utterance's interruption")
    }
}
