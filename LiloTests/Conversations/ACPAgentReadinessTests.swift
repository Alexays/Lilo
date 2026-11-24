import XCTest
@testable import Lilo

/// Probes a small agent written in Python that answers ACP over stdio the way its scenario says.
@MainActor
final class ACPAgentReadinessTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "lilo-readiness-\(UUID().uuidString)")
    private var script: URL { directory.appending(path: "agent.py") }

    private static let agent = #"""
    import json, os, sys, time
    scenario = sys.argv[1]
    if scenario == "crash":
        sys.stderr.write("npm error 404 not found\n")
        sys.exit(1)
    if scenario == "hang":
        open(sys.argv[2], "w").write(str(os.getpid()))
        time.sleep(600)
    def send(message):
        sys.stdout.write(json.dumps(message) + "\n"); sys.stdout.flush()
    for line in sys.stdin:
        message = json.loads(line)
        method, id = message.get("method"), message.get("id")
        if method == "initialize":
            result = {"protocolVersion": 1, "agentCapabilities": {}}
            if scenario == "signin":
                result["authMethods"] = [
                    {"id": "browser", "name": "Browser", "description": "Opens a page"},
                    {"id": "cli", "name": "Terminal", "type": "terminal", "args": ["login"]}]
            send({"jsonrpc": "2.0", "id": id, "result": result})
        elif method == "session/new":
            if scenario == "signin":
                send({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": "auth_required"}})
            elif scenario == "broken":
                send({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": "boom"}})
            elif scenario == "legacy":
                send({"jsonrpc": "2.0", "id": id, "result": {"sessionId": "s1",
                    "models": {"currentModelId": "fast", "availableModels": [{"modelId": "fast", "name": "Fast"}, {"modelId": "deep", "name": "Deep", "description": "Slow"}]}}})
            elif scenario == "bare":
                send({"jsonrpc": "2.0", "id": id, "result": {"sessionId": "s1"}})
            else:
                send({"jsonrpc": "2.0", "id": id, "result": {"sessionId": "s1",
                    "modes": {"currentModeId": "ask", "availableModes": [{"id": "ask", "name": "Ask"}, {"id": "code", "name": "Code", "description": "Edits files"}]},
                    "configOptions": [
                        {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "m1", "options": [
                            {"value": "m1", "name": "Model One", "description": "Small"},
                            {"group": "older", "name": "Older", "options": [{"value": "m0", "name": "Model Zero"}]}]},
                        {"id": "effort", "name": "Effort", "category": "thought_level", "type": "select", "currentValue": "low",
                         "options": [{"value": "low", "name": "Low"}]}]}})
    """#

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.agent.write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func launch(_ scenario: String, _ extra: String...) throws -> ACPAgentReadinessStore.Launch {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first(where: FileManager.default.isExecutableFile(atPath:))
        return (URL(fileURLWithPath: try XCTUnwrap(python)), [script.path, scenario] + extra, ProcessInfo.processInfo.environment)
    }

    private func probe(_ scenario: String, timeout: TimeInterval = 10) async throws -> ACPAgentReadiness {
        let launch = try launch(scenario)
        return await ACPAgentProbe.run(launching: { launch }, timeout: timeout)
    }

    func testASessionAgentIsReadyWithItsModelsAndModes() async throws {
        let result = try await probe("ready")

        XCTAssertEqual(result.state, .ready)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.models.map(\.id), ["m1", "m0"])
        XCTAssertEqual(result.models.first?.description, "Small")
        XCTAssertEqual(result.currentModel, "m1")
        XCTAssertEqual(result.modelConfigId, "model")
        XCTAssertEqual(result.modes.map(\.name), ["Ask", "Code"])
    }

    func testTheModelsBesideASessionAreReadToo() async throws {
        let result = try await probe("legacy")

        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.models.map(\.name), ["Fast", "Deep"])
        XCTAssertEqual(result.currentModel, "fast")
        XCTAssertNil(result.modelConfigId, "the earlier shape has no option to set a model through")
    }

    func testAnAgentWithNoModelsIsReadyWithNone() async throws {
        let result = try await probe("bare")

        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertTrue(result.modes.isEmpty)
    }

    func testARefusedSessionNeedsSignInAndKeepsTheMethodsTheAgentDeclares() async throws {
        let result = try await probe("signin")

        XCTAssertEqual(result.state, .needsSignIn)
        XCTAssertEqual(result.authMethods.map(\.id), ["browser", "cli"])
        XCTAssertEqual(result.authMethods.map(\.type), ["agent", "terminal"])
        XCTAssertEqual(result.authMethods.last?.args, ["login"])
    }

    func testAnErrorReplyToTheSessionLeavesTheAgentUnverifiedNotUnavailable() async throws {
        let result = try await probe("broken")

        XCTAssertEqual(result.state, .unverified)
        XCTAssertTrue(result.reason?.contains("boom") == true)
    }

    func testAProgramThatCannotBeLaunchedIsUnavailableWithTheReason() async {
        let result = await ACPAgentProbe.run(launching: {
            throw ACPAgentCatalog.LaunchError(message: "Example needs Node.js.")
        }, timeout: 5)

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.reason, "Example needs Node.js.")
    }

    func testAProgramThatExitsIsUnavailableWithItsLastWords() async throws {
        let result = try await probe("crash")

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.reason, "npm error 404 not found")
    }

    func testAnAgentThatNeverAnswersTimesOutUnverifiedAndIsStopped() async throws {
        let pidFile = directory.appending(path: "pid")
        let launch = try launch("hang", pidFile.path)

        let result = await ACPAgentProbe.run(launching: { launch }, timeout: 1)

        XCTAssertEqual(result.state, .unverified)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the probe left its agent process running")
    }

    // MARK: - The store

    func testTheStoreKeepsRecordsOnDiskAcrossARelaunch() async throws {
        let launch = try launch("ready")
        let agent = ACPAgentCatalog.Agent(id: "example", name: "Example", description: "", version: "", distribution: .command(executable: "/bin/echo", args: [], environment: ""))
        let store = ACPAgentReadinessStore(directory: directory) { _ in launch }
        XCTAssertNil(store.record(for: "example"))
        XCTAssertTrue(store.isStale("example"))

        await store.refresh(agent)

        let reloaded = ACPAgentReadinessStore(directory: directory) { _ in launch }
        XCTAssertEqual(reloaded.record(for: "example")?.state, .ready)
        XCTAssertEqual(reloaded.record(for: "example")?.models.map(\.id), ["m1", "m0"])
        XCTAssertFalse(reloaded.isStale("example"))
    }

    func testAFreshRecordIsNotProbedAgainUnlessForced() async throws {
        var launches = 0
        let launch = try launch("ready")
        let agent = ACPAgentCatalog.Agent(id: "example", name: "Example", description: "", version: "", distribution: .command(executable: "/bin/echo", args: [], environment: ""))
        let store = ACPAgentReadinessStore(directory: directory) { _ in
            launches += 1
            return launch
        }

        await store.refresh(agent)
        await store.refresh(agent)
        XCTAssertEqual(launches, 1)

        await store.refresh(agent, force: true)
        XCTAssertEqual(launches, 2)
    }

    func testARecordThatIsNotReadyIsLookedAtAgainSoonerThanOneThatIs() async throws {
        let ready = try launch("ready"), crash = try launch("crash")
        let store = ACPAgentReadinessStore(directory: directory) { $0.id == "good" ? ready : crash }
        for id in ["good", "bad"] {
            await store.refresh(ACPAgentCatalog.Agent(id: id, name: id, description: "", version: "", distribution: .command(executable: "/bin/echo", args: [], environment: "")))
        }
        XCTAssertEqual(store.record(for: "bad")?.state, .unavailable)

        let later = Date().addingTimeInterval(ACPAgentReadinessStore.notReadyMaxAge + 5)

        XCTAssertFalse(store.isStale("good", now: later))
        XCTAssertTrue(store.isStale("bad", now: later))
        XCTAssertTrue(store.isStale("good", now: Date().addingTimeInterval(ACPAgentReadinessStore.readyMaxAge + 5)))
    }

    func testThePayloadCarriesWhatTheChromeShows() {
        let record = ACPAgentReadiness(
            state: .needsSignIn, reason: nil, models: [.init(id: "m1", name: "One")], modelConfigId: "model", currentModel: "m1",
            authMethods: [.init(id: "browser", name: "Browser", type: "agent")], probedAt: Date(timeIntervalSince1970: 100))

        let payload = record.payload

        XCTAssertEqual(payload["state"] as? String, "needsSignIn")
        XCTAssertEqual(payload["probedAt"] as? Double, 100_000)
        XCTAssertEqual((payload["models"] as? [[String: Any]])?.first?["id"] as? String, "m1")
        XCTAssertEqual((payload["authMethods"] as? [[String: Any]])?.first?["type"] as? String, "agent")
        XCTAssertEqual(payload["modelConfigId"] as? String, "model")
        XCTAssertNil(payload["reason"])
    }
}
