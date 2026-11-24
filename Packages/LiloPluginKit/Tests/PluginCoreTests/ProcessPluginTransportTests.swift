import XCTest
@testable import PluginCore
import TestingSupport

/// End-to-end over the real `/bin/sh` sidecar: spawn, handshake, call, kill.
final class ProcessPluginTransportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-plugin-e2e-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testShStubHandshakeAndPing() async throws {
        let folder = root.appendingPathComponent("stub")
        let manifest = try StubPlugin.write(at: folder)
        let session = PluginSession(manifest: manifest, pluginRoot: folder)

        let ready = try await session.start()
        XCTAssertEqual(ready.protocolVersion, 1)
        XCTAssertEqual(ready.tools.map(\.name), ["stub_ping"])

        let pong = try await session.request("ping")
        XCTAssertEqual(pong, .object(["pong": .bool(true)]))
        await session.stop()
        await XCTAssertNotRunning(session)
    }

    func testShStubExitRespawns() async throws {
        let folder = root.appendingPathComponent("stub")
        let manifest = try StubPlugin.write(at: folder)
        let session = PluginSession(manifest: manifest, pluginRoot: folder)
        try await session.start()

        // "exit" ends the stub's read loop; the session reports not running.
        let exitTask = Task { try await session.request("exit") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await XCTAssertNotRunning(session)
        _ = try? await exitTask.value

        _ = try await session.request("ping")
        await XCTAssertRunning(session)
        await session.stop()
    }
}
