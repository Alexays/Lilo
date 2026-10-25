import XCTest
@testable import Lilo

/// The `lilo-mcp` binary the test host ships, driven over stdin and stdout as an agent does.
@MainActor
final class LiloMCPTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        // sun_path holds 104 bytes: the test temporary directory is too deep for the socket.
        directory = URL(fileURLWithPath: "/tmp/lilo-mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func launch(_ executable: URL? = nil, environment: [String: String]) throws -> (Process, FileHandle, FileHandle) {
        let bridge = executable ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/lilo-mcp")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else { throw XCTSkip("lilo-mcp ships only in the Xcode-built app") }
        let process = Process()
        process.executableURL = bridge
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        return (process, input.fileHandleForWriting, output.fileHandleForReading)
    }

    private func send(_ handle: FileHandle, _ id: Int, _ method: String, _ params: [String: Any] = [:]) throws {
        var line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }

    /// The next line the bridge writes, read off the main thread so Lilo keeps answering.
    private func receive(_ handle: FileHandle) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var line = Data()
                while let byte = try? handle.read(upToCount: 1), let first = byte.first, first != 0x0A { line.append(first) }
                continuation.resume(returning: (try? JSONSerialization.jsonObject(with: line)) as? [String: Any])
            }
        }
    }

    private func initialize(_ input: FileHandle) throws {
        try send(input, 1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Newcomer", "version": "1"]])
    }

    /// Asserts the handshake succeeded and every tool call fails with `reason`, as Claude Code shows them.
    private func assertAnsweredAlone(_ input: FileHandle, _ output: FileHandle, reason: String,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let handshake = await receive(output)?["result"] as? [String: Any]
        XCTAssertEqual(handshake?["protocolVersion"] as? String, "2025-06-18", file: file, line: line)
        XCTAssertTrue((handshake?["instructions"] as? String)?.contains(reason) == true, "\(handshake ?? [:])", file: file, line: line)

        try send(input, 2, "tools/list")
        let list = await receive(output)?["result"] as? [String: Any]
        XCTAssertEqual((list?["tools"] as? [Any])?.count, 0, file: file, line: line)

        try send(input, 3, "tools/call", ["name": "tabs_context_mcp", "arguments": [:]])
        let call = await receive(output)?["result"] as? [String: Any]
        XCTAssertEqual(call?["isError"] as? Bool, true, file: file, line: line)
        XCTAssertEqual((call?["_meta"] as? [String: Any])?["lilo/errorCode"] as? String, "needs_user", file: file, line: line)
        let text = ((call?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("[needs_user] ") && text.contains(reason), text, file: file, line: line)
    }

    func testWithoutLiloTheHandshakeSucceedsAtOnceAndToolCallsSayWhy() async throws {
        let started = Date()
        let (process, input, output) = try launch(environment: ["LILO_APP_SUPPORT_DIR": directory.path])
        defer { process.terminate() }
        try initialize(input)

        try await assertAnsweredAlone(input, output, reason: "Settings > AI agents > Let AI agents use Lilo")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "an agent's connect timeout never waits on Lilo")

        try input.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the agent leaving ends the bridge")
    }

    func testWithoutAWindowTheAgentConnectsAndToolCallsSayToOpenOne() async throws {
        let browserContext = try await TemporaryBrowserContext()
        let control = AgentControl(context: browserContext.context, socketURL: directory.appending(path: "agent.sock"))
        control.setEnabled(true)
        defer {
            control.setEnabled(false)
            browserContext.tearDown()
        }
        let (process, input, output) = try launch(environment: ["LILO_APP_SUPPORT_DIR": directory.path])
        defer { process.terminate() }

        try initialize(input)
        let handshake = await receive(output)?["result"] as? [String: Any]
        XCTAssertEqual((handshake?["serverInfo"] as? [String: Any])?["name"] as? String, "lilo")

        try send(input, 2, "tools/call", ["name": "tabs_context_mcp", "arguments": [:]])
        let call = await receive(output)?["result"] as? [String: Any]
        XCTAssertEqual((call?["_meta"] as? [String: Any])?["lilo/errorCode"] as? String, "needs_user")
        let text = ((call?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("[needs_user] Lilo has no window to ask the user to allow Newcomer in"), text)
        XCTAssertFalse(control.sessions.contains { $0.isRefused }, "no window is no refusal")
    }

    func testLaunchesTheAppItShipsIn() async throws {
        let app = directory.appending(path: "Shipped.app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let launched = directory.appending(path: "launched")
        try "#!/bin/sh\ntouch '\(launched.path)'\n".write(to: macOS.appending(path: "Shipped"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appending(path: "Shipped").path)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "Shipped", "CFBundleIdentifier": "fr.arouillard.lilo.tests.shipped", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let shipped = Bundle.main.bundleURL.appending(path: "Contents/MacOS/lilo-mcp")
        guard FileManager.default.isExecutableFile(atPath: shipped.path) else { throw XCTSkip("lilo-mcp ships only in the Xcode-built app") }
        let bridge = macOS.appending(path: "lilo-mcp")
        try FileManager.default.copyItem(at: shipped, to: bridge)
        defer {
            let lsregister = Process()
            lsregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            lsregister.arguments = ["-u", app.path]
            try? lsregister.run()
            lsregister.waitUntilExit()
        }

        // A home of its own: no Lilo socket, and nothing of the user's.
        let (process, input, output) = try launch(bridge, environment: ["CFFIXED_USER_HOME": directory.path])
        defer { process.terminate() }
        try initialize(input)
        _ = await receive(output)

        let opened = await pollUntil(timeout: 10) { FileManager.default.fileExists(atPath: launched.path) }
        XCTAssertTrue(opened, "the bridge opened the app it ships in")
    }
}
