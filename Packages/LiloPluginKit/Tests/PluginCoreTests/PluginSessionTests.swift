import XCTest
@testable import PluginCore
import TestingSupport

/// Polls a condition on wall time — used only to observe cross-task state the ManualClock
/// can't drive (spawn counts, sent lines).
private func waitUntil(_ timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line, _ until: @escaping @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !until(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(until(), "condition not met within \(timeout)s", file: file, line: line)
}

private final class SpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func next() -> Int {
        lock.withLock { defer { count += 1 }; return count }
    }
}

private final class TransportList: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [StubPluginTransport] = []
    func append(_ transport: StubPluginTransport) { lock.withLock { all.append(transport) } }
    subscript(index: Int) -> StubPluginTransport { lock.withLock { all[index] } }
    var count: Int { lock.withLock { all.count } }
}

final class PluginSessionTests: XCTestCase {
    /// A session whose spawn closure hands back scripted `StubPluginTransport`s.
    private func session(
        clock: ManualClock, spawns: SpawnCounter, list: TransportList = TransportList(),
        responder: @escaping @Sendable (StubPluginTransport, Data) -> Void = StubPlugin.responder()
    ) -> (PluginSession, TransportList) {
        let session = PluginSession(spawn: {
            let transport = StubPluginTransport(onSend: responder)
            list.append(transport)
            _ = spawns.next()
            return transport
        }, clock: clock)
        return (session, list)
    }

    func testHandshakeReadyAndCall() async throws {
        let (session, transports) = session(clock: ManualClock(), spawns: SpawnCounter())
        let ready = try await session.start()
        XCTAssertEqual(ready.protocolVersion, 1)
        XCTAssertEqual(ready.tools.map(\.name), ["stub_ping"])
        await XCTAssertRunning(session)

        let result = try await session.request("ping")
        XCTAssertEqual(result, .object(["pong": .bool(true)]))

        // The first two sent lines are the initialize handshake, then ping.
        let sent = transports[0].sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(sent.map { $0["method"] as? String }, ["initialize", "ping"])
    }

    func testHandshakeRejectsMismatchedProtocol() async {
        let (session, transports) = session(clock: ManualClock(), spawns: SpawnCounter()) { transport, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "initialize", let id = object["id"] else { return }
            transport.emit([
                "jsonrpc": .string("2.0"), "id": JSONValue(any: id),
                "result": .object(["protocolVersion": .number(2), "tools": .array([])])
            ])
        }
        await XCTAssertThrowsErrorAsync(try await session.start()) {
            XCTAssertEqual($0 as? PluginSessionError, .protocolMismatch)
        }
        await XCTAssertNotRunning(session)
        XCTAssertTrue(transports[0].killed)
    }

    func testDeadlineMissKillsAndNextCallRespawns() async throws {
        let clock = ManualClock()
        let spawns = SpawnCounter()
        let (session, transports) = session(clock: clock, spawns: spawns)
        try await session.start()

        let hanging = Task { try await session.request("hang") }
        await waitUntil { clock.armedCount == 1 }
        clock.advance(by: PluginSession.defaultDeadline)

        await XCTAssertThrowsErrorAsync(try await hanging.value) {
            XCTAssertEqual($0 as? PluginSessionError, .deadlineExceeded)
        }
        await XCTAssertNotRunning(session)
        XCTAssertTrue(transports[0].killed)

        // A stopped plugin is "not running", never an error: the next call respawns.
        let result = try await session.request("ping")
        XCTAssertEqual(result, .object(["pong": .bool(true)]))
        XCTAssertEqual(spawns.count, 2)
        XCTAssertNotIdentical(transports[0], transports[1])
    }

    func testCapabilityRejectionAnswersError() async throws {
        let (session, transports) = session(clock: ManualClock(), spawns: SpawnCounter())
        // The host's gate: anything not granted answers the capability error.
        await session.setOnRequest { _, _ in .failure(.capabilityNotGranted) }
        try await session.start()

        // The plugin calls a host API it was not granted.
        transports[0].emit([
            "jsonrpc": .string("2.0"), "id": .number(41),
            "method": .string("secrets.get"), "params": .object(["name": .string("apiKey")])
        ])
        await waitUntil { transports[0].sent.count >= 2 }

        let reply = try XCTUnwrap(transports[0].sent.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, PluginRequestError.capabilityNotGranted.code)
        XCTAssertEqual(object["id"] as? Int, 41)
    }

    func testUnimplementedHostMethodAnswersMethodNotFound() async throws {
        let (session, transports) = session(clock: ManualClock(), spawns: SpawnCounter())
        try await session.start()
        transports[0].emit([
            "jsonrpc": .string("2.0"), "id": .number(7), "method": .string("mystery.call")
        ])
        await waitUntil { transports[0].sent.count >= 2 }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transports[0].sent.last!) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, PluginRequestError.methodNotFound.code)
    }

    func testPluginExitRespawnsOnNextCall() async throws {
        let spawns = SpawnCounter()
        let exited = SpawnCounter()
        let (session, transports) = session(clock: ManualClock(), spawns: spawns)
        await session.setOnExit { _ = exited.next() }
        try await session.start()

        // "exit" is a notification-shaped request the stub answers by ending its stream.
        transports[0].exit()
        await waitUntil { !transports[0].isRunning }
        await waitUntil { exited.count == 1 }
        await XCTAssertNotRunning(session)

        _ = try await session.request("ping")
        XCTAssertEqual(spawns.count, 2)
    }

    func testRPCErrorPropagates() async {
        let (session, _) = session(clock: ManualClock(), spawns: SpawnCounter())
        await XCTAssertThrowsErrorAsync(try await session.request("bogus")) {
            guard case PluginSessionError.rpc(let code, let message) = $0 else {
                return XCTFail("expected rpc error, got \($0)")
            }
            XCTAssertEqual(code, -32601)
            XCTAssertEqual(message, "Method not found")
        }
    }

    func testNotificationsReachTheHandler() async throws {
        let (session, transports) = session(clock: ManualClock(), spawns: SpawnCounter())
        let seen = SpawnCounter()
        await session.setOnNotification { _, _ in _ = seen.next() }
        try await session.start()
        transports[0].emit([
            "jsonrpc": .string("2.0"), "method": .string("log"),
            "params": .object(["message": .string("hi")])
        ])
        await waitUntil { seen.count == 1 }
    }
}

private extension PluginSession {
    func setOnRequest(_ handler: @escaping @Sendable (String, JSONValue) async -> Result<JSONValue, PluginRequestError>) {
        onRequest = handler
    }
    func setOnNotification(_ handler: @escaping @Sendable (String, JSONValue) -> Void) {
        onNotification = handler
    }
    func setOnExit(_ handler: @escaping @Sendable () -> Void) {
        onExit = handler
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath, line: UInt = #line,
    _ verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}

func XCTAssertRunning(_ session: PluginSession, file: StaticString = #filePath, line: UInt = #line) async {
    let running = await session.isRunning
    XCTAssertTrue(running, file: file, line: line)
}

func XCTAssertNotRunning(_ session: PluginSession, file: StaticString = #filePath, line: UInt = #line) async {
    let running = await session.isRunning
    XCTAssertFalse(running, file: file, line: line)
}
