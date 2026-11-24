import Foundation

/// Starts an agent just long enough to ask what a conversation would learn first: its sign-in methods
/// (`initialize`) and, when it opens one, the models and modes of a session. Generic: the agent says what
/// it is; nothing here knows an agent by name.
@MainActor
enum ACPAgentProbe {
    typealias Launch = ACPAgentReadinessStore.Launch

    /// What `interrogate` learned before the agent stopped answering.
    private struct Findings: @unchecked Sendable {
        var authMethods: [ACPAgentReadiness.AuthMethod] = []
        var session: [String: Any]?
        var sessionError: ACPConnection.RPCError?
    }

    private enum Outcome: @unchecked Sendable {
        case answered(Findings)
        case failed(Error)
        case timedOut
    }

    /// Resumes one continuation with whichever of the answer and the timeout comes first.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }
        func finish(_ outcome: Outcome) {
            lock.withLock { () -> CheckedContinuation<Outcome, Never>? in
                defer { continuation = nil }
                return continuation
            }?.resume(returning: outcome)
        }
    }

    /// The agent's readiness, never throwing: a probe that cannot finish says why in its record.
    static func run(launching launch: () async throws -> Launch, timeout: TimeInterval) async -> ACPAgentReadiness {
        let now = Date()
        let resolved: Launch
        do {
            resolved = try await launch()
        } catch {
            return ACPAgentReadiness(state: .unavailable, reason: error.localizedDescription, probedAt: now)
        }
        let connection = ACPConnection(executable: resolved.executable, arguments: resolved.arguments, environment: resolved.environment,
                                       directory: FileManager.default.temporaryDirectory)
        let stderr = ErrorTail()
        connection.onExit = { status, errors in stderr.set(status: status, errors: errors) }
        connection.onMessages = { [weak connection] messages in if let connection { refuse(messages, on: connection) } }
        defer { connection.terminate(killAfter: 2) }
        do {
            try connection.start()
        } catch {
            return ACPAgentReadiness(state: .unavailable, reason: error.localizedDescription, probedAt: now)
        }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let race = Race(continuation)
            Task { race.finish(await attempt { try await interrogate(connection) }) }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                race.finish(.timedOut)
            }
        }
        switch outcome {
        case .timedOut:
            return ACPAgentReadiness(state: .unverified, reason: "The agent did not answer in time.".localized, probedAt: now)
        case .failed(let error):
            let transport = (error as? ACPConnection.RPCError)?.code == ACPConnection.RPCError.transport
            // The exit and the last words it wrote to standard error reach Lilo a moment after the failed request.
            if transport { try? await Task.sleep(for: .milliseconds(150)) }
            if transport, let exit = stderr.value {
                let reason = exit.errors.split(separator: "\n").suffix(3).joined(separator: "\n")
                return ACPAgentReadiness(state: .unavailable, reason: unsafe reason.isEmpty
                    ? String(format: "The agent stopped (code %d).".localized, exit.status) : reason, probedAt: now)
            }
            return ACPAgentReadiness(state: transport ? .unavailable : .unverified, reason: error.localizedDescription, probedAt: now)
        case .answered(let findings):
            return readiness(of: findings, at: now)
        }
    }

    /// Signs in through the agent itself (an `agent` method), which may ask for a page to open: `open` shows
    /// it. Returns the failure's text, or nil once the agent says it is signed in.
    static func signIn(launching launch: () async throws -> Launch, methodId: String, open: @escaping @MainActor (URL) -> Void) async -> String? {
        let resolved: Launch
        do { resolved = try await launch() } catch { return error.localizedDescription }
        let connection = ACPConnection(executable: resolved.executable, arguments: resolved.arguments, environment: resolved.environment,
                                       directory: FileManager.default.temporaryDirectory)
        connection.onMessages = { [weak connection] messages in
            guard let connection else { return }
            for case .request(let id, let method, let params) in messages {
                if method == "elicitation/create", params["mode"] as? String == "url", let url = (params["url"] as? String).flatMap(URL.init(string:)),
                   url.scheme == "https" || url.scheme == "http" {
                    open(url)
                    connection.respond(id: id, result: ["action": "accept"])
                } else {
                    connection.respond(id: id, errorCode: -32601, message: "Method not found")
                }
            }
        }
        defer { connection.terminate(killAfter: 2) }
        do {
            try connection.start()
            let initialized = try await initialize(connection, urlElicitation: true)
            let v2 = (initialized["protocolVersion"] as? Int ?? 1) >= 2
            _ = try await connection.request(v2 ? "auth/login" : "authenticate", ["methodId": methodId])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Asking the agent

    /// A failed step keeps what the steps before it learned.
    private static func attempt(_ body: () async throws -> Findings) async -> Outcome {
        do { return .answered(try await body()) } catch { return .failed(error) }
    }

    private static func interrogate(_ connection: ACPConnection) async throws -> Findings {
        let initialized = try await initialize(connection, urlElicitation: false)
        var findings = Findings()
        // v2 names a method's id `methodId`.
        findings.authMethods = (initialized["authMethods"] as? [[String: Any]] ?? []).compactMap { method in
            guard let id = (method["methodId"] ?? method["id"]) as? String, let name = method["name"] as? String else { return nil }
            return ACPAgentReadiness.AuthMethod(id: id, name: name, type: method["type"] as? String ?? "agent",
                                                description: method["description"] as? String, args: method["args"] as? [String] ?? [])
        }
        do {
            findings.session = try await connection.request("session/new", ["cwd": FileManager.default.temporaryDirectory.path, "mcpServers": [Any]()])
        } catch let error as ACPConnection.RPCError where error.code != ACPConnection.RPCError.transport {
            findings.sessionError = error
        }
        return findings
    }

    /// A v2 agent answers 2 and reads the v2 fields; a v1 agent that rejects those gets the v1 request alone.
    private static func initialize(_ connection: ACPConnection, urlElicitation: Bool) async throws -> [String: Any] {
        let info = ["name": "lilo", "title": "Lilo", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
        var elicitation: [String: Any] = ["form": [String: Any]()]
        if urlElicitation { elicitation["url"] = [String: Any]() }
        do {
            return try await connection.request("initialize", [
                "protocolVersion": ConversationHost.protocolVersion, "info": info,
                "capabilities": ["auth": ["terminal": [String: Any]()], "elicitation": elicitation]
            ])
        } catch let error as ACPConnection.RPCError where error.code != ACPConnection.RPCError.transport {
            return try await connection.request("initialize", [
                "protocolVersion": 1, "clientInfo": info,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false,
                                       "auth": ["terminal": true], "elicitation": elicitation]
            ])
        }
    }

    /// An agent asking the probe for anything (a permission, a file) gets a refusal, so it never waits on it.
    private static func refuse(_ messages: [ACPConnection.Incoming], on connection: ACPConnection) {
        for case .request(let id, _, _) in messages { connection.respond(id: id, errorCode: -32601, message: "Method not found") }
    }

    // MARK: - Reading the answers

    private static func readiness(of findings: Findings, at date: Date) -> ACPAgentReadiness {
        var result = ACPAgentReadiness(state: .ready, authMethods: findings.authMethods, probedAt: date)
        if let error = findings.sessionError {
            // -32000 is ACP's `auth_required`.
            if error.code == -32000 {
                result.state = .needsSignIn
                result.reason = findings.authMethods.isEmpty ? error.message : nil
            } else {
                result.state = .unverified
                result.reason = unsafe String(format: "The agent could not open a session: %@".localized, error.message)
            }
            return result
        }
        guard let session = findings.session else {
            result.state = .unverified
            return result
        }
        let options = (session["configOptions"] as? [[String: Any]] ?? [])
        if let model = options.first(where: { $0["category"] as? String == "model" }) {
            result.models = choices(in: model["options"] as? [[String: Any]] ?? [], id: ["value", "id"])
            result.currentModel = model["currentValue"] as? String
            result.modelConfigId = (model["configId"] ?? model["id"]) as? String
        } else if let models = session["models"] as? [String: Any] {
            // ACP's earlier shape: the models beside the session, not among its options.
            result.models = choices(in: models["availableModels"] as? [[String: Any]] ?? [], id: ["modelId", "id"])
            result.currentModel = models["currentModelId"] as? String
        }
        if let modes = session["modes"] as? [String: Any] {
            result.modes = choices(in: modes["availableModes"] as? [[String: Any]] ?? [], id: ["id"])
        } else if let mode = options.first(where: { $0["category"] as? String == "mode" }) {
            result.modes = choices(in: mode["options"] as? [[String: Any]] ?? [], id: ["value", "id"])
        }
        return result
    }

    /// An option list is flat or in groups, each holding its own `options`.
    private static func choices(in entries: [[String: Any]], id keys: [String]) -> [ACPAgentReadiness.Choice] {
        entries.flatMap { entry -> [ACPAgentReadiness.Choice] in
            if let group = entry["options"] as? [[String: Any]] { return choices(in: group, id: keys) }
            guard let id = keys.lazy.compactMap({ entry[$0] as? String }).first else { return [] }
            return [ACPAgentReadiness.Choice(id: id, name: entry["name"] as? String ?? id, description: entry["description"] as? String)]
        }
    }

    /// The exit status and last words of an agent that stopped, set on the main actor and read after it.
    private final class ErrorTail: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (status: Int32, errors: String)?
        var value: (status: Int32, errors: String)? { lock.withLock { stored } }
        func set(status: Int32, errors: String) { lock.withLock { stored = (status, errors) } }
    }
}
