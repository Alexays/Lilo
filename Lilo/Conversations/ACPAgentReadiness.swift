import Foundation
import os

/// What the last probe of an agent found: whether it can be used now, the models and modes a session
/// offers, and the sign-in methods it declares. Nothing here is required to start an agent: a missing or
/// failed record only means Lilo does not know yet.
struct ACPAgentReadiness: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case ready
        /// The agent refused a session until the user signs in.
        case needsSignIn
        /// Its program could not be found, installed or kept running: it cannot start.
        case unavailable
        /// The probe itself failed (no answer, an error reply) though the agent may work: still pickable.
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
    /// The session option that sets the model, which a model chosen before the session exists goes to.
    var modelConfigId: String?
    var currentModel: String?
    var modes: [Choice] = []
    var authMethods: [AuthMethod] = []
    var probedAt: Date

    /// The record as the chrome's `BridgeAgentReadiness`.
    var payload: [String: Any] {
        var data: [String: Any] = ["state": state.rawValue, "probedAt": probedAt.timeIntervalSince1970 * 1000]
        if let reason { data["reason"] = reason }
        if !models.isEmpty { data["models"] = models.map(Self.payload) }
        if let modelConfigId { data["modelConfigId"] = modelConfigId }
        if let currentModel { data["currentModel"] = currentModel }
        if !modes.isEmpty { data["modes"] = modes.map(Self.payload) }
        if !authMethods.isEmpty {
            data["authMethods"] = authMethods.map { method in
                var entry: [String: Any] = ["id": method.id, "name": method.name, "type": method.type]
                if let description = method.description { entry["description"] = description }
                return entry
            }
        }
        return data
    }

    private static func payload(_ choice: Choice) -> [String: Any] {
        var entry: [String: Any] = ["id": choice.id, "name": choice.name]
        if let description = choice.description { entry["description"] = description }
        return entry
    }
}

/// The readiness of each agent by id, kept on disk so it survives a relaunch. Probing starts an agent,
/// which may install it: it runs only when the user asks or a stale record is looked at, never at idle.
@MainActor
final class ACPAgentReadinessStore {
    typealias Launch = (executable: URL, arguments: [String], environment: [String: String])

    /// A record of an agent that works is trusted this long; one that does not is looked at again sooner,
    /// as the user may have fixed it since.
    static let readyMaxAge: TimeInterval = 15 * 60
    static let notReadyMaxAge: TimeInterval = 60
    private static let logger = Logger(liloCategory: "acp-readiness")

    private let file: URL
    private let launch: (ACPAgentCatalog.Agent) async throws -> Launch
    private(set) var records: [String: ACPAgentReadiness]
    private var running: [String: Task<ACPAgentReadiness, Never>] = [:]
    /// Terminal tabs running an agent's sign-in, with the agent each one signs in.
    private var signInTerminals: [UUID: ACPAgentCatalog.Agent] = [:]
    /// Called with the agent id whenever its record changes or a probe starts or ends.
    var onChange: ((_ agentId: String) -> Void)?
    var timeout: TimeInterval = 60

    init(directory: URL, launch: @escaping (ACPAgentCatalog.Agent) async throws -> Launch) {
        file = directory.appending(path: "readiness.json")
        self.launch = launch
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        records = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([String: ACPAgentReadiness].self, from: $0) } ?? [:]
    }

    func record(for id: String) -> ACPAgentReadiness? { records[id] }

    func isChecking(_ id: String) -> Bool { running[id] != nil }

    func isStale(_ id: String, now: Date = Date()) -> Bool {
        guard let record = records[id] else { return true }
        let limit = record.state == .ready ? Self.readyMaxAge : Self.notReadyMaxAge
        return now.timeIntervalSince(record.probedAt) >= limit
    }

    /// Probes `agent` unless a recent record exists (`force` skips that check); one probe per agent runs at a time.
    @discardableResult
    func refresh(_ agent: ACPAgentCatalog.Agent, force: Bool = false) async -> ACPAgentReadiness {
        if let running = running[agent.id] { return await running.value }
        if !force, let record = records[agent.id], !isStale(agent.id) { return record }
        let launch = launch, timeout = timeout
        let task = Task { await ACPAgentProbe.run(launching: { try await launch(agent) }, timeout: timeout) }
        running[agent.id] = task
        onChange?(agent.id)
        let result = await task.value
        running[agent.id] = nil
        records[agent.id] = result
        save()
        onChange?(agent.id)
        return result
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            Self.logger.error("saving readiness failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Signing in from Settings

    /// Signs in with one of the methods the last probe found, then probes the agent again. A `terminal`
    /// method runs the agent's launch command with the method's arguments in a terminal tab, and the probe
    /// follows when that command ends; an `agent` method runs through the agent, whose page to open, if
    /// any, opens in a tab. False when the method is unknown or its sign-in could not start.
    @discardableResult
    func signIn(_ agent: ACPAgentCatalog.Agent, methodId: String, in window: MainWindowController) async -> Bool {
        guard let method = records[agent.id]?.authMethods.first(where: { $0.id == methodId }) else { return false }
        let launch = launch
        if method.type != "terminal" {
            let failure = await ACPAgentProbe.signIn(launching: { try await launch(agent) }, methodId: methodId, open: { url in
                window.createTabStateFirst(url: url)
            })
            if let failure { Self.logger.info("sign-in failed: \(failure, privacy: .public)") }
            await refresh(agent, force: true)
            return failure == nil
        }
        guard let resolved = try? await launch(agent) else { return false }
        let words = [resolved.executable.path] + resolved.arguments + method.args
        let command = "PATH='\(resolved.environment["PATH"] ?? "")' " + words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        guard let tab = window.createTerminalTab(command: command) else { return false }
        signInTerminals[tab.id] = agent
        return true
    }

    /// A terminal's command ended or its tab closed: the sign-in run there is done, so the agent is looked at again.
    func terminalFinished(_ terminalId: UUID) {
        guard let agent = signInTerminals.removeValue(forKey: terminalId) else { return }
        Task { await refresh(agent, force: true) }
    }
}
