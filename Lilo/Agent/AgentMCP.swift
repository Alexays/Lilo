import Foundation

/// The MCP subset Lilo serves: the handshake, tool listing and tool calls, over JSON-RPC 2.0.
@MainActor
enum AgentMCP {
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    /// Tool calls past this many seconds are stopped and answered with an error.
    static var toolDeadline: TimeInterval = 60

    static func handle(_ message: [String: Any]?, session: AgentSession, control: AgentControl) async -> [String: Any]? {
        guard let message else { return error(id: NSNull(), code: -32700, message: "Parse error") }
        guard let method = message["method"] as? String else {
            // The client answering one of Lilo's own requests.
            if let id = message["id"] as? String, let handle = session.pendingReplies.removeValue(forKey: id) {
                handle(message["result"] as? [String: Any])
            }
            return nil
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"] else {
            // Its project folder names its tab folder; the client answers once the handshake is over.
            if method == "notifications/initialized", session.supportsRoots { Task { await fetchProjectName(session, control: control) } }
            if method == "notifications/cancelled", let requestId = params["requestId"] as? AnyHashable { session.requests[requestId]?.cancel() }
            return nil
        }
        session.lastActivity = Date()
        if method.hasPrefix("tools/"), !session.isAuthorized { return error(id: id, code: -32002, message: "Call initialize first") }
        switch method {
        case "initialize":
            if let name = (params["clientInfo"] as? [String: Any])?["name"] as? String, !name.isEmpty { session.clientName = name }
            session.supportsRoots = (params["capabilities"] as? [String: Any])?["roots"] != nil
            session.isAuthorized = await control.authorize(session)
            guard session.isAuthorized else {
                session.isRefused = true
                let message = control.context?.windows.windows.isEmpty ?? true
                    ? "Open a Lilo window so Lilo can ask the user to allow \(session.clientName), then reconnect the lilo MCP server"
                    : "The user did not allow \(session.clientName) to control Lilo"
                return error(id: id, code: -32001, message: message, data: ["code": "needs_user"])
            }
            control.resumeDroppedSession(into: session)
            control.refreshControlledTabs()
            control.publishActivity()
            let requested = params["protocolVersion"] as? String ?? ""
            return result(id: id, [
                "protocolVersion": supportedProtocolVersions.contains(requested) ? requested : supportedProtocolVersions.last!,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "lilo",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                ]
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": AgentTools.definitions])
        case "tools/call":
            // Queued behind a freeze, a request whose client cancelled it or left does nothing.
            guard !Task.isCancelled else { return nil }
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            session.activeCalls += 1
            let startedAt = Date()
            session.callStartedAt = startedAt
            control.publishActivity()
            control.context?.powerKeeper.browserAgentWorked(session.id)
            defer {
                session.activeCalls -= 1
                // The tabs this call touched keep their dot a moment after it ends, then lose it.
                let now = Date()
                for (id, at) in session.actedOn where at >= startedAt { session.actedOn[id] = now }
                control.publishActivity()
                DispatchQueue.main.asyncAfter(deadline: .now() + AgentControl.actingLinger + 0.1) { [weak control] in control?.publishActivity() }
            }
            // A call the client stopped waiting for still runs: one after it on the same tab runs alongside.
            let tab = (arguments["tabId"] as? NSNumber)?.intValue
            let callId = UUID()
            let overlapping = session.tabCalls.values.filter { $0.tab == tab }.sorted { $0.startedAt < $1.startedAt }
            if let tab { session.tabCalls[callId] = (tab, name, startedAt) }
            let warning = overlapping.map { call in
                "Warning: \(call.tool), called \(Int(startedAt.timeIntervalSince(call.startedAt))) s ago on this tab, " +
                    "was still running when this call began: both ran at the same time on the page."
            }
            // The call may outlive its reply (a page script that never settles ignores cancellation): its tab
            // stays busy until it really ends.
            let work = Task {
                defer { session.tabCalls[callId] = nil }
                return try await AgentTools.call(name, arguments: arguments, session: session, control: control)
            }
            // The profile tools bound their own waits, which may take minutes; a script may ask for its own.
            let takesTimeout = name == "javascript_tool" || name == "run"
            let timeout = takesTimeout ? (arguments["timeout"] as? NSNumber).map { min(max($0.doubleValue, 1), 600) } : nil
            let deadline = name.hasSuffix("_profile") ? nil : timeout ?? toolDeadline
            // Cancelled once the call ends, so it stops holding the call's result.
            var timer: Task<Void, Never>?
            defer { timer?.cancel() }
            do {
                let content = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AgentContent], Error>) in
                        var finished = false
                        let finish = { (outcome: Result<[AgentContent], Error>) in
                            guard !finished else { return }
                            finished = true
                            continuation.resume(with: outcome)
                        }
                        Task { finish(await work.result) }
                        guard let deadline else { return }
                        timer = Task {
                            try? await Task.sleep(for: .seconds(deadline))
                            guard !Task.isCancelled else { return }
                            work.cancel()
                            finish(.failure(AgentToolError("\(name) did not finish within \(Int(deadline)) s and was stopped: the page may be busy or unresponsive"
                                + (takesTimeout ? " (pass timeout for a longer limit)" : ""))))
                        }
                    }
                } onCancel: {
                    work.cancel()
                }
                return result(id: id, ["content": (warning.map(AgentContent.text) + content).map(\.json)])
            } catch {
                let code = (error as? AgentToolError)?.code
                let text = (warning + [(code.map { "[\($0)] " } ?? "") + error.localizedDescription]).joined(separator: "\n")
                var reply: [String: Any] = ["content": [AgentContent.text(text).json], "isError": true]
                if let code { reply["_meta"] = ["lilo/errorCode": code] }
                return result(id: id, reply)
            }
        default:
            return self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// The client's first project folder, asked with `roots/list`; nil when it does not answer within two seconds.
    private static func fetchProjectName(_ session: AgentSession, control: AgentControl) async {
        let id = "lilo-\(session.nextRequestId)"
        session.nextRequestId += 1
        let name = await withCheckedContinuation { (reply: CheckedContinuation<String?, Never>) in
            session.pendingReplies[id] = { result in
                let first = (result?["roots"] as? [[String: Any]])?.first
                reply.resume(returning: first?["name"] as? String ?? (first?["uri"] as? String).flatMap(URL.init(string:))?.lastPathComponent)
            }
            if let line = AgentConnection.line(["jsonrpc": "2.0", "id": id, "method": "roots/list"]) { session.connection.send(line) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak session] in session?.pendingReplies.removeValue(forKey: id)?(nil) }
        }
        guard let name, !name.isEmpty else { return }
        session.projectName = name
        control.renameFolder(of: session)
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        error["data"] = data
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }
}

enum AgentContent {
    case text(String)
    /// A PNG, base64 encoded off the main thread.
    case image(String)

    var json: [String: Any] {
        switch self {
        case .text(let text): ["type": "text", "text": text]
        case .image(let base64): ["type": "image", "data": base64, "mimeType": "image/png"]
        }
    }
}

struct AgentToolError: LocalizedError {
    let message: String
    /// Stable and machine-readable, sent as `_meta["lilo/errorCode"]`: "needs_user" when only the user can unblock the call.
    let code: String?
    init(_ message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
    var errorDescription: String? { message }
}
