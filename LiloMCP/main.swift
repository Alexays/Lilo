import Darwin
import Foundation

// lilo-mcp: what an agent launches as its MCP server. Lilo itself serves MCP on its agent socket;
// this pipes stdin and stdout to it, starting Lilo first when it is not running,
// and reconnecting when Lilo restarts. When Lilo cannot take the agent, it answers alone with the reason.

let socketPath = URL(fileURLWithPath: BuildIdentity.appSupportDirectory).appending(path: "agent.sock").path
// Longer than Lilo's own 60 second tool deadline, so only a frozen Lilo hits it.
let timeout: TimeInterval = 90
let newline = Data([0x0A])

func connectToLilo() -> Int32? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { close(fd); return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    // A frozen Lilo that stops reading must not block the agent's writes, which hold the bridge lock.
    var wait = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

/// False once `fd` stops taking bytes.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

/// Splits what `fd` sends into lines without their newline; nil at the end, on an error or a read timeout.
struct LineReader {
    let fd: Int32
    var buffer = Data()
    var scanned = 0
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    mutating func next() -> Data? {
        while true {
            if let end = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<end)
                buffer.removeSubrange(buffer.startIndex...end)
                scanned = 0
                return line
            }
            scanned = buffer.count
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(chunk, count: count)
        }
    }
}

/// What the agent and Lilo directions share, guarded by `lock`.
final class Bridge: @unchecked Sendable {
    let lock = NSLock()
    var lilo: Int32
    /// The agent's requests Lilo has not answered yet, by id, with when they count as unanswered.
    var pending: [String: (id: Any, deadline: Date)] = [:]
    /// The agent's initialize request until Lilo answers it.
    var initialize: (key: String, line: Data)?
    /// The initialize request Lilo accepted, replayed on every reconnection.
    var accepted: (key: String, line: Data)?
    /// Why Lilo cannot take the agent, once known: from then on the bridge answers alone.
    var unavailable: String?

    init(lilo: Int32) { self.lilo = lilo }
}

let output = NSLock()

/// Sends one whole line to the agent; two threads write to stdout.
func send(_ line: Data) {
    output.lock()
    defer { output.unlock() }
    guard writeAll(STDOUT_FILENO, line), writeAll(STDOUT_FILENO, newline) else { exit(0) }
}

/// `needsUser` adds `data: {code: "needs_user"}`, as Lilo's own errors that only the user can resolve.
func fail(_ id: Any, _ message: String, needsUser: Bool = false) {
    var error: [String: Any] = ["code": -32000, "message": message]
    if needsUser { error["data"] = ["code": "needs_user"] }
    let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": error]
    if let data = try? JSONSerialization.data(withJSONObject: reply) { send(data) }
}

func reply(_ id: Any, _ result: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]) { send(data) }
}

/// Answers in Lilo's stead: the handshake succeeds and every tool call fails with the reason, so the
/// agent reads why rather than a server that failed to start.
func answerAlone(_ message: [String: Any], reason: String) {
    guard let method = message["method"] as? String, let id = message["id"], !(id is NSNull) else { return }
    switch method {
    case "initialize":
        let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
        reply(id, [
            "protocolVersion": requested ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "lilo", "version": "0"],
            "instructions": "Lilo is unavailable: \(reason)"
        ])
    case "ping": reply(id, [:])
    case "tools/list": reply(id, ["tools": [Any]()])
    case "tools/call":
        reply(id, ["content": [["type": "text", "text": "[needs_user] \(reason)"]], "isError": true, "_meta": ["lilo/errorCode": "needs_user"]])
    default: fail(id, reason, needsUser: true)
    }
}

/// Reconnects once Lilo is back and replays the agent's handshake; exits when Lilo stays away.
func reconnect(_ bridge: Bridge) -> LineReader {
    bridge.lock.lock()
    defer { bridge.lock.unlock() }
    close(bridge.lilo)
    for request in bridge.pending.values { fail(request.id, "Lilo restarted: try again.") }
    bridge.pending = [:]
    // Never accepted (refused, or gone mid-handshake): reconnecting would only ask the user again.
    guard let accepted = bridge.accepted else { exit(0) }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        usleep(500_000)
        guard let fd = connectToLilo() else { continue }
        // Lilo answers initialize only once the user allows the agent, which can take a while.
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var reader = LineReader(fd: fd)
        guard writeAll(fd, accepted.line), writeAll(fd, newline) else { close(fd); continue }
        // The agent already has its initialize reply: swallow this one.
        while let line = reader.next() {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  message["method"] == nil, let id = message["id"], "\(id)" == accepted.key else { continue }
            guard message["result"] != nil else { exit(1) }
            wait = timeval()
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            guard writeAll(fd, Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)),
                  writeAll(fd, newline) else { break }
            bridge.lilo = fd
            return reader
        }
        close(fd)
    }
    exit(1)
}

signal(SIGPIPE, SIG_IGN)
var connection = connectToLilo()
// A LILO_APP_SUPPORT_DIR socket belongs to a Lilo its harness started: opening the app would not serve it.
if connection == nil, ProcessInfo.processInfo.environment["LILO_APP_SUPPORT_DIR"]?.isEmpty ?? true {
    // The app this binary ships in, so a debug build's bridge never opens another build.
    let app = Bundle.main.executableURL.map {
        $0.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }.flatMap { $0.pathExtension == "app" ? $0 : nil }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = app.map { ["-g", $0.path] } ?? ["-g", "-b", BuildIdentity.appIdentifier]
    try? open.run()
    // Short, and not waiting for `open` itself (it can hang): the agent's handshake must not wait on a launch.
    let deadline = Date().addingTimeInterval(2)
    while connection == nil, Date() < deadline {
        usleep(100_000)
        connection = connectToLilo()
    }
}

let bridge = Bridge(lilo: connection ?? -1)
if connection == nil {
    bridge.unavailable = FileManager.default.fileExists(atPath: socketPath)
        ? "Lilo is not responding: quit and reopen Lilo, then reconnect the lilo MCP server."
        : "Lilo is not accepting agents: in Lilo, turn on Settings > AI agents > Let AI agents use Lilo, then reconnect the lilo MCP server."
}

Thread.detachNewThread {
    var agent = LineReader(fd: STDIN_FILENO)
    let conversation = ProcessInfo.processInfo.environment["LILO_CONVERSATION"].flatMap { $0.isEmpty ? nil : $0 }
    while var line = agent.next() {
        var message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        // An agent Lilo started for a conversation says so in its handshake, which ties its tabs to that conversation.
        if let conversation, var initialize = message, initialize["method"] as? String == "initialize" {
            var params = initialize["params"] as? [String: Any] ?? [:]
            var meta = params["_meta"] as? [String: Any] ?? [:]
            meta["lilo/conversation"] = conversation
            params["_meta"] = meta
            initialize["params"] = params
            if let rewritten = try? JSONSerialization.data(withJSONObject: initialize) {
                line = rewritten
                message = initialize
            }
        }
        bridge.lock.lock()
        if let reason = bridge.unavailable {
            bridge.lock.unlock()
            if let message { answerAlone(message, reason: reason) }
            continue
        }
        // Requests only: a line with an id and no method answers one of Lilo's own requests.
        if let message, let method = message["method"] as? String, let id = message["id"], !(id is NSNull) {
            // A tool call may ask Lilo for a longer limit or wait, and a profile switch may wait on the user's answer.
            let params = message["params"] as? [String: Any]
            let arguments = params?["arguments"] as? [String: Any]
            let asked = ["timeout", "wait"].compactMap { (arguments?[$0] as? NSNumber)?.doubleValue }.max() ?? 0
            let consent: TimeInterval = (params?["name"] as? String)?.hasSuffix("_profile") == true ? 120 : 0
            bridge.pending["\(id)"] = (id, Date().addingTimeInterval(timeout + min(max(asked, 0), 600) + consent))
            if method == "initialize" { bridge.initialize = ("\(id)", line) }
        }
        _ = writeAll(bridge.lilo, line) && writeAll(bridge.lilo, newline)
        bridge.lock.unlock()
    }
    // The agent is gone: give Lilo a moment to answer what is in flight, never waiting on a frozen one.
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if bridge.lock.lock(before: deadline) {
            let done = bridge.pending.isEmpty
            bridge.lock.unlock()
            if done { break }
        }
        usleep(50_000)
    }
    exit(0)
}

Thread.detachNewThread {
    while true {
        sleep(5)
        bridge.lock.lock()
        let expired = bridge.pending.filter { $0.value.deadline < Date() }
        for key in expired.keys { bridge.pending[key] = nil }
        bridge.lock.unlock()
        for request in expired.values { fail(request.id, "Lilo is not responding: quit and reopen Lilo.", needsUser: true) }
    }
}

// Unreachable, the agent's thread answers alone, and exits when the agent leaves.
guard let connection else { dispatchMain() }
var reader = LineReader(fd: connection)
while true {
    guard let line = reader.next() else {
        reader = reconnect(bridge)
        continue
    }
    if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
       message["method"] == nil, let id = message["id"], !(id is NSNull) {
        bridge.lock.lock()
        let answered = bridge.pending.removeValue(forKey: "\(id)") != nil
        var refused: (request: Data, reason: String)?
        if let initialize = bridge.initialize, initialize.key == "\(id)" {
            if answered, message["result"] != nil { bridge.accepted = initialize }
            // An initialize error reads as a broken server: the bridge answers alone with its reason.
            if answered, bridge.accepted == nil, let error = message["error"] as? [String: Any] {
                refused = (initialize.line, error["message"] as? String ?? "Lilo refused the agent.")
                bridge.unavailable = refused?.reason
            }
            bridge.initialize = nil
        }
        bridge.lock.unlock()
        if let refused, let request = (try? JSONSerialization.jsonObject(with: refused.request)) as? [String: Any] {
            answerAlone(request, reason: refused.reason)
            close(connection)
            dispatchMain()
        }
        // Already answered with a timeout error.
        guard answered else { continue }
    }
    send(line)
}
