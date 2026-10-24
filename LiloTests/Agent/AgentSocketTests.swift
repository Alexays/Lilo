import XCTest
@testable import Lilo

@MainActor
final class AgentSocketTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var control: AgentControl!
    // sun_path holds 104 bytes: the test temporary directory is too deep for it.
    private let socketURL = URL(fileURLWithPath: "/tmp/lilo-agent-\(UUID().uuidString.prefix(8)).sock")

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        browserContext.context.settingsStore.set("agentAllowedClients", value: AgentToolTestCase.allowedClientsJSON)
        control = AgentControl(context: browserContext.context, socketURL: socketURL)
        control.setEnabled(true)
    }

    override func tearDown() {
        control.setEnabled(false)
        control = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    func testSocketIsUserOnly() throws {
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: socketURL.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
    }

    func testInitializeRoundTrip() async throws {
        let client = try AgentTestClient(path: socketURL)

        let result = await client.initialize(name: "Codex")

        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "lilo")
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(control.sessions.first?.clientName, "Codex")
    }

    func testNotificationsGetNoReplyAndUnknownMethodsAnError() async throws {
        let client = try AgentTestClient(path: socketURL)
        client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let reply = await client.request("resources/list")

        XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32601, "the notification got no reply, so this is the next one")
    }

    func testDisabledRemovesSocket() {
        control.setEnabled(false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testMalformedJSONReturnsParseError() async throws {
        let client = try AgentTestClient(path: socketURL)
        client.sendRaw(Data("{nope\n".utf8))

        let reply = await client.receive()
        let ping = await client.request("ping")

        XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertNotNil(ping, "the connection stays open")
    }

    func testOversizedMessageClosesConnection() async throws {
        let client = try AgentTestClient(path: socketURL)
        let chunk = Data(repeating: 0x61, count: 1024 * 1024)
        Task.detached { for _ in 0...AgentConnection.maxMessageBytes / chunk.count { client.sendRaw(chunk) } }

        let reply = await client.receive()
        let other = try AgentTestClient(path: socketURL)
        let ping = await other.request("ping")

        XCTAssertNil(reply, "Lilo closed the connection")
        XCTAssertNotNil(ping, "and still accepts new ones")
    }

    func testDisconnectEndsSession() async throws {
        let client = try AgentTestClient(path: socketURL)
        _ = await client.initialize()
        XCTAssertEqual(control.sessions.count, 1)

        client.close()

        let ended = await pollUntil(timeout: 5) { self.control.sessions.isEmpty }
        XCTAssertTrue(ended)
    }

    func testStopAllClosesEverySession() async throws {
        let first = try AgentTestClient(path: socketURL)
        let second = try AgentTestClient(path: socketURL)
        _ = await first.initialize()
        _ = await second.initialize(name: "Codex")

        control.stopAll()
        let ended = await pollUntil(timeout: 5) { self.control.sessions.isEmpty }
        XCTAssertTrue(ended)

        let afterFirst = await first.receive()
        let afterSecond = await second.receive()
        XCTAssertNil(afterFirst)
        XCTAssertNil(afterSecond)
    }

    func testClosingAConnectionWhoseClientStoppedReadingFreesIt() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[1]) }
        // As the server sets on every accepted client, with a shorter send timeout.
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(pair[0], SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connection = AgentConnection(fd: pair[0])
        // Far more than the socket buffer, and the peer never reads: the write blocks.
        connection.send(try XCTUnwrap(AgentConnection.line(["data": String(repeating: "x", count: 8 * 1024 * 1024)])))
        let writing = await pollUntil {
            var byte: UInt8 = 0
            return recv(pair[1], &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 1
        }
        XCTAssertTrue(writing)

        connection.close()

        let closed = await pollUntil(timeout: 5) { fcntl(pair[0], F_GETFD) == -1 }
        XCTAssertTrue(closed, "the descriptor is closed, not queued behind the stuck write")
    }

    func testRepliesPilingUpForAClientThatStoppedReadingCloseTheConnection() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[1]) }
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connection = AgentConnection(fd: pair[0])
        let line = try XCTUnwrap(AgentConnection.line(["data": String(repeating: "x", count: 1024 * 1024)]))

        for _ in 0...(AgentConnection.maxPendingBytes / line.count) { connection.send(line) }

        XCTAssertTrue(connection.isClosed)
    }

    func testUnknownToolReportsAnError() async throws {
        let client = try AgentTestClient(path: socketURL)
        _ = await client.initialize()

        let result = await client.callTool("no_such_tool")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no_such_tool"))
    }
}
