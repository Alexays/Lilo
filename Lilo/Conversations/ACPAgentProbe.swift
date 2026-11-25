import Foundation

/// Starts an agent just long enough to do what a conversation would do first: `initialize`, an optional
/// sign-in, then `session/new`. Generic: the agent says what it is; nothing here knows an agent by name.
@MainActor
enum ACPAgentProbe {
    /// The agent's readiness, never throwing: a check that cannot finish says why in its record. Past
    /// `timeout`, the agent is stopped, which fails the request it has not answered.
    static func run(launching launch: () async throws -> ACPAgentReadinessStore.Launch, signingInWith methodId: String?,
                    open: @escaping @MainActor (URL) -> Void, timeout: TimeInterval) async -> ACPAgentReadiness {
        let connection: ACPConnection
        do {
            let resolved = try await launch()
            connection = ACPConnection(executable: resolved.executable, arguments: resolved.arguments, environment: resolved.environment,
                                       directory: FileManager.default.temporaryDirectory)
            connection.onMessages = { [weak connection] messages in
                guard let connection else { return }
                for case .request(let id, let method, let params) in messages {
                    // The user asked for this sign-in: its page opens. Anything else the agent asks is refused.
                    if method == "elicitation/create", methodId != nil, let url = ConversationHost.signInURL(params) {
                        open(url)
                        connection.respond(id: id, result: ["action": "accept"])
                    } else {
                        connection.respond(id: id, errorCode: -32601, message: "Method not found")
                    }
                }
            }
            try connection.start()
        } catch {
            return ACPAgentReadiness(state: .unavailable, reason: error.localizedDescription)
        }
        defer { connection.terminate(killAfter: 2) }
        let timer = Task { () -> Bool in
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return false }
            connection.terminate(killAfter: 2)
            return true
        }
        defer { timer.cancel() }
        var authMethods: [[String: Any]] = []
        do {
            let initialized: [String: Any]
            do {
                initialized = try await connection.request("initialize", ConversationHost.initializeParams(v2: true))
            } catch let error as ACPConnection.RPCError where error.code != ACPConnection.RPCError.transport {
                initialized = try await connection.request("initialize", ConversationHost.initializeParams(v2: false))
            }
            authMethods = initialized["authMethods"] as? [[String: Any]] ?? []
            if let methodId {
                let v2 = (initialized["protocolVersion"] as? Int ?? 1) >= 2
                _ = try await connection.request(v2 ? "auth/login" : "authenticate", ["methodId": methodId])
            }
            let session = try await connection.request("session/new", ["cwd": FileManager.default.temporaryDirectory.path, "mcpServers": [Any]()])
            return ACPAgentReadiness(session: session, authMethods: authMethods)
        } catch let error as ACPConnection.RPCError {
            timer.cancel()
            if await timer.value { return ACPAgentReadiness(state: .unverified, reason: "The agent did not answer in time.".localized, authMethods: authMethods) }
            // -32000 is ACP's `auth_required`.
            if error.code == -32000 { return ACPAgentReadiness(state: .needsSignIn, authMethods: authMethods) }
            return ACPAgentReadiness(state: error.code == ACPConnection.RPCError.transport ? .unavailable : .unverified,
                                     reason: error.message, authMethods: authMethods)
        } catch {
            return ACPAgentReadiness(state: .unverified, reason: error.localizedDescription, authMethods: authMethods)
        }
    }
}
