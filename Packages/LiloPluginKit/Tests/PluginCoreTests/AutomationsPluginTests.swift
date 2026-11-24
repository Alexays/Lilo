import XCTest
@testable import PluginCore
import TestingSupport

/// The bundled Automations sidecar, run for real over stdio against a scripted host: a
/// `schedule.fire` notification must come back as the host calls its steps make.
final class AutomationsPluginTests: XCTestCase {
    private var root: URL!
    private var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    private var watched: URL { support.appendingPathComponent("watched", isDirectory: true) }
    private var host: ScriptedHost!
    private var session: PluginSession!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-automations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        // #filePath: <repo>/Packages/LiloPluginKit/Tests/PluginCoreTests/<this file>
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("Plugins/automations"), to: folder)
        let manifest = try PluginManifest.load(at: folder)
        XCTAssertEqual(manifest.capabilities.map(\.rawValue).sorted(), ["schedule", "settings:store", "tabs:open", "tabs:read"])

        host = ScriptedHost()
        let supportPath = support.path
        session = PluginSession(manifest: manifest, pluginRoot: folder, initializeParams: {
            ["supportDir": .string(supportPath)]
        })
        await session.set(onRequest: { [host] method, params in await host!.answer(method, params) }, onExit: {})
        try await session.start()
    }

    override func tearDown() async throws {
        await session.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, at date: Date, steps: [String]) throws {
        let at = ISO8601DateFormatter().string(from: date)
        try (["# \(name)", "at \(at)"] + steps).joined(separator: "\n")
            .write(to: watched.appendingPathComponent("\(name).auto"), atomically: true, encoding: .utf8)
    }

    /// The sidecar handles messages in order, so answering an unknown method means every earlier
    /// notification has been handled.
    private func settle() async {
        _ = try? await session.request("barrier")
    }

    private func state(_ name: String) -> String? {
        try? String(contentsOf: support.appendingPathComponent("state/\(name).done"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testFileChangeArmsTheScheduleAndRemovingTheFileCancelsIt() async throws {
        try write("daily", at: Date().addingTimeInterval(3600), steps: ["open https://example.com/a"])
        await session.notify("files.changed")
        await settle()

        let armed = await host.calls
        XCTAssertEqual(armed.map(\.method), ["schedule.set"])
        XCTAssertEqual(armed[0].params["id"], .string("daily"))
        guard case .number(let delay)? = armed[0].params["delay"] else { return XCTFail("no delay") }
        XCTAssertEqual(delay, 3600, accuracy: 5)

        // Unchanged file: nothing re-armed. Deleted file: its job is cancelled.
        await session.notify("files.changed")
        await settle()
        let unchanged = await host.calls.count
        XCTAssertEqual(unchanged, 1)

        try FileManager.default.removeItem(at: watched.appendingPathComponent("daily.auto"))
        await session.notify("files.changed")
        await settle()
        let cancelled = await host.calls
        XCTAssertEqual(cancelled.map(\.method), ["schedule.set", "schedule.cancel"])
        XCTAssertEqual(cancelled[1].params["id"], .string("daily"))
    }

    func testFireRunsEveryStepThroughHostCalls() async throws {
        await host.set(tabs: ["https://example.com/already"], approve: true)
        try write("report", at: Date().addingTimeInterval(60), steps: [
            "open https://example.com/dashboard",
            "ensure https://example.com/already",
            "ensure https://example.com/new",
            "ask Open the weekly report too?",
            "open https://example.com/weekly"
        ])
        await session.notify("schedule.fire", params: ["id": .string("report")])
        await settle()

        let calls = await host.calls
        XCTAssertEqual(calls.map(\.method), ["settings.get", "tabs.open", "tabs.list", "tabs.list", "tabs.open", "ask", "tabs.open"])
        XCTAssertEqual(calls[1].params["url"], .string("https://example.com/dashboard"))
        XCTAssertEqual(calls[4].params["url"], .string("https://example.com/new"))
        XCTAssertEqual(calls[5].params["message"], .string("Open the weekly report too?"))
        XCTAssertEqual(calls[5].params["timeout"], .number(15 * 60))
        XCTAssertEqual(calls[6].params["url"], .string("https://example.com/weekly"))
        XCTAssertEqual(state("report"), "completed")

        // A duplicate fire (at-least-once delivery) does nothing.
        await session.notify("schedule.fire", params: ["id": .string("report")])
        await settle()
        let after = await host.calls.count
        XCTAssertEqual(after, calls.count)
    }

    func testADeniedApprovalStopsTheRun() async throws {
        await host.set(tabs: [], approve: false)
        try write("gated", at: Date().addingTimeInterval(60), steps: [
            "open https://example.com/first", "ask Continue?", "open https://example.com/never"
        ])
        await session.notify("schedule.fire", params: ["id": .string("gated")])
        await settle()

        let methods = await host.calls.map(\.method)
        XCTAssertEqual(methods, ["settings.get", "tabs.open", "ask"])
        XCTAssertEqual(state("gated"), "stopped at step 2: not approved")
    }

    func testAnUnknownStepFailsTheRunAndOverdueFilesAreHandled() async throws {
        try write("bad", at: Date().addingTimeInterval(60), steps: ["frobnicate now"])
        await session.notify("schedule.fire", params: ["id": .string("bad")])
        await settle()
        XCTAssertEqual(state("bad"), "failed at step 1: unknown step \"frobnicate\"")

        // Overdue by an hour: re-armed at once. Overdue by two days: expired, never run.
        try write("late", at: Date().addingTimeInterval(-3600), steps: ["open https://example.com/a"])
        try write("stale", at: Date().addingTimeInterval(-2 * 86400), steps: ["open https://example.com/a"])
        await session.notify("files.changed")
        await settle()
        let sets = await host.calls.filter { $0.method == "schedule.set" }
        XCTAssertEqual(sets.map { $0.params["id"] }, [.string("late")])
        XCTAssertEqual(sets.first?.params["delay"], .number(0))
        XCTAssertEqual(state("stale"), "expired")
    }

    func testAHostWithoutTheTabsHandlerFailsTheRunInsteadOfHanging() async throws {
        await host.set(tabs: nil, approve: true)
        try write("blind", at: Date().addingTimeInterval(60), steps: ["open https://example.com/a", "open https://example.com/b"])
        await session.notify("schedule.fire", params: ["id": .string("blind")])
        await settle()
        XCTAssertEqual(state("blind"), "failed at step 1: tabs.open")
    }
}

/// The host side of the plugin RPC: records calls and answers like `PluginHost` would.
actor ScriptedHost {
    struct Call { let method: String; let params: [String: JSONValue] }
    private(set) var calls: [Call] = []
    private var tabs: [String]? = []
    private var approve = true

    func set(tabs: [String]?, approve: Bool) {
        self.tabs = tabs
        self.approve = approve
    }

    func answer(_ method: String, _ params: JSONValue) -> Result<JSONValue, PluginRequestError> {
        var object: [String: JSONValue] = [:]
        if case .object(let fields) = params { object = fields }
        calls.append(Call(method: method, params: object))
        switch method {
        case "settings.get": return .success(.object(["askTimeoutMinutes": .string("15")]))
        case "schedule.set", "schedule.cancel": return .success(.null)
        case "tabs.list", "tabs.open":
            guard let tabs else { return .failure(.methodNotFound) }
            return .success(method == "tabs.list"
                ? .object(["tabs": .array(tabs.map { .object(["url": .string($0)]) })]) : .null)
        case "ask": return .success(.object(["approved": .bool(approve)]))
        default: return .failure(.methodNotFound)
        }
    }
}
