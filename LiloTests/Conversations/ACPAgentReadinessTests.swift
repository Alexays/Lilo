import XCTest
@testable import Lilo

/// Checks a small agent written in Python that answers ACP over stdio the way its scenario says.
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
    signed_in = False
    for line in sys.stdin:
        message = json.loads(line)
        method, id = message.get("method"), message.get("id")
        if method == "authenticate":
            signed_in = True
            send({"jsonrpc": "2.0", "id": id, "result": {}})
        elif method == "initialize":
            result = {"protocolVersion": 1, "agentCapabilities": {}}
            if scenario == "signin":
                result["authMethods"] = [
                    {"id": "browser", "name": "Browser", "description": "Opens a page"},
                    {"id": "cli", "name": "Terminal", "type": "terminal", "args": ["login"]}]
            send({"jsonrpc": "2.0", "id": id, "result": result})
        elif method == "session/new":
            if scenario == "signin" and not signed_in:
                send({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": "auth_required"}})
            elif scenario == "broken":
                send({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": "boom"}})
            elif scenario in ("bare", "signin"):
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

    private func probe(_ scenario: String, signingInWith methodId: String? = nil, timeout: TimeInterval = 10) async throws -> ACPAgentReadiness {
        let launch = try launch(scenario)
        return await ACPAgentProbe.run(launching: { launch }, signingInWith: methodId, open: { _ in }, timeout: timeout)
    }

    private func agent(_ id: String = "example") -> ACPAgentCatalog.Agent {
        ACPAgentCatalog.Agent(id: id, name: id, description: "", version: "", distribution: .command(executable: "/bin/echo", args: [], environment: ""))
    }

    func testASessionAgentIsReadyWithItsModels() async throws {
        let result = try await probe("ready")

        XCTAssertEqual(result.state, .ready)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.models.map(\.id), ["m1", "m0"])
        XCTAssertEqual(result.models.first?.description, "Small")
        XCTAssertEqual(result.currentModel, "m1")
        XCTAssertEqual(result.modelConfigId, "model")
    }

    func testAnAgentWithNoModelsIsReadyWithNone() async throws {
        let result = try await probe("bare")

        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertNil(result.payload["models"])
    }

    func testARefusedSessionNeedsSignInAndKeepsTheMethodsTheAgentDeclares() async throws {
        let result = try await probe("signin")

        XCTAssertEqual(result.state, .needsSignIn)
        XCTAssertEqual(result.authMethods.map(\.id), ["browser", "cli"])
        XCTAssertEqual(result.authMethods.map(\.type), ["agent", "terminal"])
        XCTAssertEqual(result.authMethods.last?.args, ["login"])
    }

    func testASignInThroughTheAgentLeavesItReady() async throws {
        let result = try await probe("signin", signingInWith: "browser")

        XCTAssertEqual(result.state, .ready)
    }

    func testAnErrorReplyToTheSessionLeavesTheAgentUnverifiedNotUnavailable() async throws {
        let result = try await probe("broken")

        XCTAssertEqual(result.state, .unverified)
        XCTAssertEqual(result.reason, "boom")
    }

    func testAProgramThatCannotBeLaunchedIsUnavailableWithTheReason() async {
        let result = await ACPAgentProbe.run(launching: {
            throw ACPAgentCatalog.LaunchError(message: "Example needs Node.js.")
        }, signingInWith: nil, open: { _ in }, timeout: 5)

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.reason, "Example needs Node.js.")
    }

    func testAProgramThatExitsIsUnavailableWithoutWhatItWroteToStandardError() async throws {
        let result = try await probe("crash")

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertFalse(result.reason?.contains("npm") ?? true)
    }

    func testAnAgentThatNeverAnswersTimesOutUnverifiedAndIsStopped() async throws {
        let pidFile = directory.appending(path: "pid")
        let launch = try launch("hang", pidFile.path)

        let result = await ACPAgentProbe.run(launching: { launch }, signingInWith: nil, open: { _ in }, timeout: 1)

        XCTAssertEqual(result.state, .unverified)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the check left its agent process running")
    }

    // MARK: - The store

    func testTheStoreKeepsRecordsOnDiskAcrossARelaunch() async throws {
        let launch = try launch("ready")
        let store = ACPAgentReadinessStore(directory: directory) { _ in launch }
        XCTAssertNil(store.record(for: "example"))

        await store.check(agent())

        let reloaded = ACPAgentReadinessStore(directory: directory) { _ in launch }
        XCTAssertEqual(reloaded.record(for: "example")?.state, .ready)
        XCTAssertEqual(reloaded.record(for: "example")?.models.map(\.id), ["m1", "m0"])
    }

    func testOneCheckRunsPerAgentAtATime() async throws {
        var launches = 0
        let launch = try launch("ready")
        let store = ACPAgentReadinessStore(directory: directory) { _ in
            launches += 1
            return launch
        }

        async let first: Void = store.check(agent())
        async let second: Void = store.check(agent())
        _ = await (first, second)

        XCTAssertEqual(launches, 1)
        XCTAssertTrue(store.checking.isEmpty)
    }

    func testAnUnchangedRecordIsNotSavedOrAnnouncedAgain() async throws {
        let store = ACPAgentReadinessStore(directory: directory) { _ in throw ACPAgentCatalog.LaunchError(message: "unused") }
        var changes = 0
        store.onChange = { _ in changes += 1 }

        store.set(ACPAgentReadiness(state: .needsSignIn), for: "example")
        store.set(ACPAgentReadiness(state: .needsSignIn), for: "example")

        XCTAssertEqual(changes, 1)
    }
}
