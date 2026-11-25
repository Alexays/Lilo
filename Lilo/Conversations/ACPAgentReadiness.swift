import Foundation
import os

/// What Lilo last learned of an agent, from a conversation it started or a check the user asked for: whether
/// it can be used, the models a session offers and the sign-in methods it declares. Nothing here is required
/// to start an agent, and no state keeps one from being picked.
struct ACPAgentReadiness: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case ready
        /// The agent refused a session until the user signs in.
        case needsSignIn
        /// Its program could not be found, installed or kept running.
        case unavailable
        /// The check itself failed (no answer, an error reply) though the agent may work.
        case unverified
    }

    struct Choice: Codable, Equatable, Sendable {
        let id: String
        let name: String
        var description: String?
    }

    struct AuthMethod: Codable, Equatable, Sendable {
        let id: String
        let name: String
        /// `agent`: the agent signs in by itself (often through the browser); `terminal`: it runs a command.
        let type: String
        var description: String?
        var args: [String] = []
    }

    var state: State
    var reason: String?
    var models: [Choice] = []
    /// The session option that sets the model: a model picked before the session exists is remembered for it.
    var modelConfigId: String?
    var currentModel: String?
    var authMethods: [AuthMethod] = []

    /// An agent that opened `session`: its model option, when it has one. v2 names a method's id `methodId`.
    init(session: [String: Any], authMethods: [[String: Any]]) {
        self.init(state: .ready, authMethods: authMethods)
        guard let model = (session["configOptions"] as? [[String: Any]])?.first(where: { $0["category"] as? String == "model" }) else { return }
        models = Self.choices(in: model["options"] as? [[String: Any]] ?? [])
        currentModel = model["currentValue"] as? String
        modelConfigId = (model["configId"] ?? model["id"]) as? String
    }

    init(state: State, reason: String? = nil, authMethods: [[String: Any]] = []) {
        self.state = state
        self.reason = reason
        self.authMethods = authMethods.compactMap { method in
            guard let id = (method["methodId"] ?? method["id"]) as? String, let name = method["name"] as? String else { return nil }
            return AuthMethod(id: id, name: name, type: method["type"] as? String ?? "agent",
                              description: method["description"] as? String, args: method["args"] as? [String] ?? [])
        }
    }

    /// An option list is flat or in groups, each holding its own `options`.
    private static func choices(in entries: [[String: Any]]) -> [Choice] {
        entries.flatMap { entry -> [Choice] in
            if let group = entry["options"] as? [[String: Any]] { return choices(in: group) }
            guard let id = entry["value"] as? String else { return [] }
            return [Choice(id: id, name: entry["name"] as? String ?? id, description: entry["description"] as? String)]
        }
    }

    /// The record as the chrome's `BridgeAgentReadiness`.
    var payload: [String: Any] {
        var data: [String: Any] = ["state": state.rawValue]
        if let reason { data["reason"] = reason }
        if let modelConfigId, !models.isEmpty {
            data["modelConfigId"] = modelConfigId
            data["models"] = models.map { choice in
                var entry: [String: Any] = ["id": choice.id, "name": choice.name]
                if let description = choice.description { entry["description"] = description }
                return entry
            }
        }
        if let currentModel { data["currentModel"] = currentModel }
        if !authMethods.isEmpty {
            data["authMethods"] = authMethods.map { method in
                var entry: [String: Any] = ["id": method.id, "name": method.name, "type": method.type]
                if let description = method.description { entry["description"] = description }
                return entry
            }
        }
        return data
    }
}

/// The readiness of each agent by id, kept on disk so it survives a relaunch. Conversations update it as
/// they start; an agent starts here only for a check or a sign-in the user asked for in Settings.
@MainActor
final class ACPAgentReadinessStore {
    typealias Launch = (executable: URL, arguments: [String], environment: [String: String])

    private static let logger = Logger(liloCategory: "acp-readiness")

    private let file: URL
    private let launch: (ACPAgentCatalog.Agent) async throws -> Launch
    private(set) var records: [String: ACPAgentReadiness]
    /// The agents a check or a sign-in runs for: one at a time each.
    private(set) var checking: Set<String> = []
    /// Terminal tabs running an agent's sign-in, with the agent each one signs in.
    private var signInTerminals: [UUID: ACPAgentCatalog.Agent] = [:]
    /// Called with the agent id whenever its record changes or a check starts or ends.
    var onChange: ((_ agentId: String) -> Void)?
    var timeout: TimeInterval = 60
    /// A sign-in waits on the user, in a browser page.
    var signInTimeout: TimeInterval = 300

    init(directory: URL, launch: @escaping (ACPAgentCatalog.Agent) async throws -> Launch) {
        file = directory.appending(path: "readiness.json")
        self.launch = launch
        records = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: ACPAgentReadiness].self, from: $0) } ?? [:]
    }

    func record(for id: String) -> ACPAgentReadiness? { records[id] }

    /// Saves and announces a record only when it says something new.
    func set(_ record: ACPAgentReadiness, for id: String) {
        guard records[id] != record else { return }
        records[id] = record
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
        } catch {
            Self.logger.error("saving readiness failed: \(error.localizedDescription, privacy: .public)")
        }
        onChange?(id)
    }

    /// Starts `agent` to check it, or to sign in with an `agent` method first, whose page to open goes to `open`.
    func check(_ agent: ACPAgentCatalog.Agent, signingInWith methodId: String? = nil, open: @escaping @MainActor (URL) -> Void = { _ in }) async {
        guard checking.insert(agent.id).inserted else { return }
        onChange?(agent.id)
        let launch = launch
        let result = await ACPAgentProbe.run(launching: { try await launch(agent) }, signingInWith: methodId, open: open,
                                             timeout: methodId == nil ? timeout : signInTimeout)
        checking.remove(agent.id)
        set(result, for: agent.id)
        onChange?(agent.id)
    }

    /// Signs in with one of the methods the agent declared. A `terminal` method runs the agent's launch command
    /// with the method's arguments in a terminal tab, and the agent is checked when that command ends.
    func signIn(_ agent: ACPAgentCatalog.Agent, methodId: String, in window: MainWindowController) async {
        guard let method = records[agent.id]?.authMethods.first(where: { $0.id == methodId }) else { return }
        guard method.type == "terminal" else {
            await check(agent, signingInWith: methodId) { [weak window] url in window?.createTabStateFirst(url: url) }
            return
        }
        guard !signInTerminals.values.contains(where: { $0.id == agent.id }), let resolved = try? await launch(agent),
              let tab = window.createTerminalTab(command: ConversationHost.shellCommand(resolved, arguments: method.args)) else { return }
        signInTerminals[tab.id] = agent
    }

    /// A terminal's command ended or its tab closed: the sign-in run there is done, so the agent is checked again.
    func terminalFinished(_ terminalId: UUID) {
        guard let agent = signInTerminals.removeValue(forKey: terminalId) else { return }
        Task { await check(agent) }
    }
}
