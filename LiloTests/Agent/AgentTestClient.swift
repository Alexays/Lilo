import Darwin
import Foundation
@testable import Lilo

/// A raw client of the agent socket, as an MCP client would talk to it.
final class AgentTestClient: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private var nextId = 1
    /// Project folders it answers Lilo's roots/list with, as an agent in a project does.
    var roots: [String] = []

    init(path: URL) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw AgentToolError("connect failed: \(errno)") }
        // Only a hang ends here: a closed connection reads at once, and a loaded machine can take
        // longer than 10 s to answer a call that opens an inspector.
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { Darwin.close(fd) }

    func close() { shutdown(fd, SHUT_RDWR) }

    func sendRaw(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    func send(_ message: [String: Any]) {
        var data = try! JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        sendRaw(data)
    }

    /// The next message from Lilo, or nil when the connection closed or nothing came within 60 s. Lilo's own
    /// roots/list requests are answered on the way.
    func receive() async -> [String: Any]? {
        while true {
            // A blocking read on a GCD thread: many clients reading at once must not starve the cooperative pool Lilo needs.
            let line = await withCheckedContinuation { continuation in DispatchQueue.global().async { continuation.resume(returning: self.readLine()) } }
            guard let message = line
                .flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }) else { return nil }
            guard message["method"] as? String == "roots/list", let id = message["id"] else { return message }
            send(["jsonrpc": "2.0", "id": id, "result": ["roots": roots.map { ["uri": $0] }]])
        }
    }

    /// Sends a request and returns its reply's `result`, or the whole reply when it is an error.
    func request(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
        let id = nextId
        nextId += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let reply = await receive() else { return nil }
        return reply["result"] as? [String: Any] ?? reply
    }

    func initialize(name: String = "Test Agent") async -> [String: Any]? {
        let capabilities: [String: Any] = roots.isEmpty ? [:] : ["roots": [String: Any]()]
        let reply = await request("initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": name, "version": "1"], "capabilities": capabilities])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return reply
    }

    /// Calls a tool and returns its text content joined, whether it reported an error, and its `_meta`.
    func callTool(_ name: String, _ arguments: [String: Any] = [:]) async -> (text: String, isError: Bool, images: [Data], meta: [String: Any]) {
        let result = await request("tools/call", ["name": name, "arguments": arguments]) ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let images = content.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        return (text, result["isError"] as? Bool ?? (result["error"] != nil), images, result["_meta"] as? [String: Any] ?? [:])
    }

    private func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
