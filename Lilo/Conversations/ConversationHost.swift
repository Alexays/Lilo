import AppKit
import Foundation
import os
import UserNotifications

/// Conversations with ACP agents, one per agent tab. An agent starts on a conversation's first use and
/// stops once idle; its session comes back with `session/load`. What a conversation shows is the log of
/// the agent's `session/update` notifications plus Lilo's own entries (`lilo_*`), which the chrome replays
/// when the conversation comes on screen, then receives as they arrive.
@MainActor
final class ConversationHost {
    enum State: String {
        case idle, starting, busy, failed
    }

    final class Conversation {
        let tabId: UUID
        let agentId: String
        var cwd: String
        var sessionId: String?
        var connection: ACPConnection?
        var starting: Task<Void, Error>?
        var state = State.idle
        var log: [ACPConnection.Payload] = []
        /// The agent's open `session/request_permission`, answered from the thread, the sidebar or a notification.
        var permission: (id: ACPConnection.Payload, requestId: String, params: [String: Any])?
        var queued: [[[String: Any]]] = []
        /// The project's files when each prompt was sent, by prompt index: what "Restore to here" goes back to.
        var checkpoints: [String?] = []
        var canLoadSession = false
        var acceptsImages = false
        var authMethods: [[String: Any]] = []
        /// Replays of `session/load` repeat what the log already holds after an idle stop.
        var replaying = false
        var title = ""
        var unread = false
        var lastError: String?
        var idleStop: DispatchWorkItem?
        var keptAwakeAt = Date.distantPast
        /// The log saved by a previous run was read back, or there was none.
        var restored = false
        /// The conversation's folder: its pages, and the agent's MCP folder.
        var folderId: UUID?
        var spaceId: UUID?
        /// Ties the agent's `lilo-mcp` to this conversation (`LILO_CONVERSATION`).
        let token = UUID().uuidString

        init(tabId: UUID, agentId: String, cwd: String, sessionId: String?) {
            self.tabId = tabId
            self.agentId = agentId
            self.cwd = cwd
            self.sessionId = sessionId
        }
    }

    static let protocolVersion = 1
    static let idleDelay: TimeInterval = 600
    private static let logger = Logger(liloCategory: "conversations")

    weak var context: BrowserContext?
    let catalog: ACPAgentCatalog
    let projectFiles = ConversationProjectFiles()
    private(set) var conversations: [UUID: Conversation] = [:]
    /// The conversations each window's chrome shows, so updates go only where they are seen.
    private var shown: [ObjectIdentifier: Set<UUID>] = [:]
    private var summaryScheduled = false
    private var diffRefresh: Set<UUID> = []

    /// Each conversation's log and checkpoints, so a relaunch shows the thread without starting its agent.
    private let threads: URL

    init(directory: URL) {
        catalog = ACPAgentCatalog(directory: directory)
        threads = directory.appending(path: "Conversations")
    }

    func conversation(forToken token: String) -> Conversation? {
        conversations.values.first { $0.token == token }
    }

    /// Registers an agent tab, restored or new; its agent starts only when it is first needed.
    @discardableResult
    func register(_ tab: Tab, folderId: UUID?) -> Conversation? {
        guard tab.kind == .agent, let agentId = tab.agentId else { return nil }
        if let existing = conversations[tab.id] {
            existing.folderId = folderId ?? existing.folderId
            return existing
        }
        let conversation = Conversation(tabId: tab.id, agentId: agentId, cwd: tab.cwd ?? NSHomeDirectory(), sessionId: tab.agentSessionId)
        conversation.folderId = folderId
        conversation.spaceId = tab.spaceId
        conversation.title = tab.title
        conversations[tab.id] = conversation
        scheduleSummary()
        return conversation
    }

    func close(_ tabId: UUID) {
        guard let conversation = conversations.removeValue(forKey: tabId) else { return }
        conversation.idleStop?.cancel()
        conversation.starting?.cancel()
        conversation.connection?.terminate()
        for key in shown.keys { shown[key]?.remove(tabId) }
        withdrawNotification(tabId)
        scheduleSummary()
        // A conversation reopened with Reopen Closed Tab gets its thread back from the agent's session.
        try? FileManager.default.removeItem(at: threadFile(tabId))
    }

    /// Stops every agent, at quit: their sessions resume next launch.
    func stopAll() {
        for conversation in conversations.values {
            conversation.connection?.terminate()
            if conversation.restored { save(conversation, synchronously: true) }
        }
    }

    private func threadFile(_ tabId: UUID) -> URL { threads.appending(path: "\(tabId.uuidString).json") }

    /// Written off the main thread, but at quit, where the app must not exit before it is on disk.
    private func save(_ conversation: Conversation, synchronously: Bool = false) {
        let object: [String: Any] = ["log": conversation.log.map(\.value), "checkpoints": conversation.checkpoints.map { $0 ?? "" }]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let file = threadFile(conversation.tabId), folder = threads
        let write = {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        if synchronously { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    /// The thread a previous run saved; with none, the agent's session replays it once the agent starts.
    private func restoreThread(_ conversation: Conversation) {
        guard !conversation.restored else { return }
        conversation.restored = true
        guard conversation.log.isEmpty else { return }
        if let data = try? Data(contentsOf: threadFile(conversation.tabId)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            conversation.log = (object["log"] as? [[String: Any]] ?? []).map(ACPConnection.Payload.init(value:))
            conversation.checkpoints = (object["checkpoints"] as? [String] ?? []).map { $0.isEmpty ? nil : $0 }
        } else if conversation.sessionId != nil {
            Task { try? await ensureStarted(conversation) }
        }
    }

    var busyCount: Int { conversations.values.filter { $0.state == .busy }.count }

    // MARK: - Chrome subscriptions

    func show(_ tabId: UUID, in window: MainWindowController, visible: Bool) {
        let key = ObjectIdentifier(window)
        if visible {
            shown[key, default: []].insert(tabId)
            guard let conversation = conversations[tabId] else { return }
            restoreThread(conversation)
            if conversation.unread {
                conversation.unread = false
                updateTab(conversation)
            }
            withdrawNotification(tabId)
            window.bridgeRouter.send(event: "conversationOpened", data: openedPayload(conversation))
        } else {
            shown[key]?.remove(tabId)
        }
    }

    func windowClosed(_ window: MainWindowController) {
        shown[ObjectIdentifier(window)] = nil
    }

    private func isShown(_ tabId: UUID) -> Bool {
        shown.values.contains { $0.contains(tabId) } && NSApp.isActive
    }

    private func openedPayload(_ conversation: Conversation) -> [String: Any] {
        var data: [String: Any] = [
            "tabId": conversation.tabId.uuidString,
            "agentId": conversation.agentId,
            "cwd": conversation.cwd,
            "state": conversation.state.rawValue,
            "updates": conversation.log.map(\.value),
            "checkpoints": conversation.checkpoints.map { $0 != nil }
        ]
        if let error = conversation.lastError { data["error"] = error }
        return data
    }

    private func append(_ conversation: Conversation, _ update: [String: Any]) {
        conversation.log.append(ACPConnection.Payload(value: update))
        guard let windows = context?.windows.windows else { return }
        for window in windows where shown[ObjectIdentifier(window)]?.contains(conversation.tabId) == true {
            window.bridgeRouter.send(event: "conversationUpdate", data: ["tabId": conversation.tabId.uuidString, "update": update])
        }
    }

    // MARK: - Starting the agent

    private func ensureStarted(_ conversation: Conversation) async throws {
        conversation.idleStop?.cancel()
        if conversation.connection != nil, conversation.sessionId != nil, conversation.starting == nil { return }
        if let starting = conversation.starting { return try await starting.value }
        let task = Task { try await start(conversation) }
        conversation.starting = task
        defer { conversation.starting = nil }
        try await task.value
    }

    private func start(_ conversation: Conversation) async throws {
        setState(conversation, .starting)
        await catalog.load()
        guard let agent = catalog.agent(id: conversation.agentId) else {
            throw ACPAgentCatalog.LaunchError(message: "This agent is no longer in the ACP registry.".localized)
        }
        let launch = try await catalog.launch(agent)
        var environment = launch.environment
        environment["LILO_CONVERSATION"] = conversation.token
        let directory = URL(fileURLWithPath: conversation.cwd, isDirectory: true)
        let connection = ACPConnection(executable: launch.executable, arguments: launch.arguments, environment: environment, directory: directory)
        connection.onMessages = { [weak self, weak conversation] messages in
            guard let self, let conversation else { return }
            for message in messages { self.receive(message, from: conversation) }
        }
        connection.onExit = { [weak self, weak conversation, weak connection] status, errors in
            guard let self, let conversation, conversation.connection === connection else { return }
            self.agentExited(conversation, status: status, errors: errors)
        }
        try connection.start()
        conversation.connection = connection
        let initialized = try await connection.request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false, "auth": ["terminal": true]],
            "clientInfo": ["name": "lilo", "title": "Lilo", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
        ])
        let capabilities = initialized["agentCapabilities"] as? [String: Any] ?? [:]
        conversation.canLoadSession = capabilities["loadSession"] as? Bool ?? false
        conversation.acceptsImages = (capabilities["promptCapabilities"] as? [String: Any])?["image"] as? Bool ?? false
        conversation.authMethods = initialized["authMethods"] as? [[String: Any]] ?? []
        try await openSession(conversation, connection: connection)
        setState(conversation, .idle)
    }

    private func openSession(_ conversation: Conversation, connection: ACPConnection) async throws {
        let servers: [[String: Any]] = [[
            "name": "lilo",
            "command": AgentClientConfig.helperPath,
            "args": [String](),
            "env": [["name": "LILO_CONVERSATION", "value": conversation.token]]
        ]]
        if let sessionId = conversation.sessionId, conversation.canLoadSession {
            conversation.replaying = !conversation.log.isEmpty
            defer { conversation.replaying = false }
            do {
                let loaded = try await withAuthentication(conversation, connection: connection) {
                    try await connection.request("session/load", ["sessionId": sessionId, "cwd": conversation.cwd, "mcpServers": servers])
                }
                applySessionState(conversation, loaded)
                return
            } catch let error as ACPConnection.RPCError where error.code != -32000 {
                // A session the agent no longer has starts over in a new one.
                Self.logger.info("session/load failed, starting a new session: \(error.message, privacy: .public)")
            }
        }
        let created = try await withAuthentication(conversation, connection: connection) {
            try await connection.request("session/new", ["cwd": conversation.cwd, "mcpServers": servers])
        }
        guard let sessionId = created["sessionId"] as? String else {
            throw ACPConnection.RPCError(code: -32603, message: "The agent did not open a session")
        }
        conversation.sessionId = sessionId
        applySessionState(conversation, created)
        persistSession(conversation)
    }

    /// A first `session/new` an agent refuses for want of a sign-in: Lilo signs in with the method the
    /// agent handles itself, then tries again. A sign-in in a terminal is the user's to do.
    private func withAuthentication(
        _ conversation: Conversation, connection: ACPConnection, _ body: () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await body()
        } catch let error as ACPConnection.RPCError where error.code == -32000 {
            if let method = conversation.authMethods.first(where: { ($0["type"] as? String ?? "agent") == "agent" }),
               let methodId = method["id"] as? String {
                _ = try await connection.request("authenticate", ["methodId": methodId])
                return try await body()
            }
            if let method = conversation.authMethods.first(where: { $0["type"] as? String == "terminal" }) {
                signInInTerminal(conversation, method: method)
                throw ACPAgentCatalog.LaunchError(message: "Sign in in the terminal Lilo opened, then send your message again.".localized)
            }
            throw error
        }
    }

    /// Runs the agent's own sign-in, its launch command with the method's arguments, in a terminal tab.
    private func signInInTerminal(_ conversation: Conversation, method: [String: Any]) {
        guard let agent = catalog.agent(id: conversation.agentId), let window = context?.windows.activeWindow else { return }
        Task {
            guard let launch = try? await catalog.launch(agent) else { return }
            let words = [launch.executable.path] + launch.arguments + (method["args"] as? [String] ?? [])
            let command = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            _ = window.createTerminalTab(command: "PATH='\(launch.environment["PATH"] ?? "")' " + command)
        }
    }

    private func applySessionState(_ conversation: Conversation, _ result: [String: Any]) {
        var update: [String: Any] = ["sessionUpdate": "lilo_session"]
        if let modes = result["modes"] as? [String: Any] { update["modes"] = modes }
        if let options = result["configOptions"] as? [Any] { update["configOptions"] = options }
        if update.count > 1 { append(conversation, update) }
    }

    private func persistSession(_ conversation: Conversation) {
        guard let window = context?.windows.window(forTab: conversation.tabId) else { return }
        _ = window.updateRuntimeTab(id: conversation.tabId) { $0.agentSessionId = conversation.sessionId }
        window.profileContext?.sessionPersistence?.scheduleSave()
    }

    private func agentExited(_ conversation: Conversation, status: Int32, errors: String) {
        conversation.connection = nil
        if let permission = conversation.permission {
            append(conversation, ["sessionUpdate": "lilo_permission_resolved", "requestId": permission.requestId, "optionId": NSNull()])
            conversation.permission = nil
        }
        // An agent Lilo stopped once idle exits cleanly; any other exit is the agent failing.
        if conversation.state == .idle, status == 0 || status == SIGTERM || status == 15 { return }
        let reason = errors.split(separator: "\n").suffix(3).joined(separator: "\n")
        conversation.lastError = reason.isEmpty ? String(format: "The agent stopped (code %d).".localized, status) : reason
        append(conversation, ["sessionUpdate": "lilo_error", "message": conversation.lastError ?? ""])
        setState(conversation, .failed)
    }

    // MARK: - Turns

    /// Shows a prompt in the thread the moment it is sent, and marks the conversation working, before its
    /// attachments are read: `send` follows with them. False for a conversation that is gone.
    func announce(_ tabId: UUID, text: String, context chips: [[String: Any]]) -> Bool {
        guard let conversation = conversations[tabId] else { return false }
        restoreThread(conversation)
        // Timed, as the turn's end is, so a thread read back from disk still says how long each turn took.
        append(conversation, ["sessionUpdate": "lilo_user", "text": text, "context": chips, "at": Date().timeIntervalSince1970 * 1000])
        if conversation.state != .busy { setState(conversation, .starting) }
        return true
    }

    /// Sends a prompt `announce` showed, or queues it behind the running turn; `interrupt` cancels that turn first.
    func send(_ tabId: UUID, blocks: [[String: Any]], interrupt: Bool) {
        guard let conversation = conversations[tabId] else { return }
        conversation.checkpoints.append(nil)
        let index = conversation.checkpoints.count - 1
        let cwd = conversation.cwd
        Task.detached(priority: .utility) {
            let tree = ConversationCheckpoints.snapshot(in: cwd)
            await MainActor.run { [weak self] in
                guard let self, let conversation = self.conversations[tabId], index < conversation.checkpoints.count, let tree else { return }
                conversation.checkpoints[index] = tree
                self.append(conversation, ["sessionUpdate": "lilo_checkpoint", "index": index])
            }
        }
        if conversation.state == .busy {
            if interrupt {
                conversation.queued.insert(blocks, at: 0)
                cancel(tabId)
            } else {
                conversation.queued.append(blocks)
                append(conversation, ["sessionUpdate": "lilo_queued", "count": conversation.queued.count])
            }
            return
        }
        Task { await runTurn(conversation, blocks: blocks) }
    }

    private func runTurn(_ conversation: Conversation, blocks: [[String: Any]]) async {
        conversation.lastError = nil
        setState(conversation, .busy)
        do {
            try await ensureStarted(conversation)
            guard let connection = conversation.connection, let sessionId = conversation.sessionId else { return }
            setState(conversation, .busy)
            // Only once started does Lilo know whether the agent takes images.
            let prompt = conversation.acceptsImages ? blocks : blocks.filter { $0["type"] as? String != "image" }
            let result = try await connection.request("session/prompt", ["sessionId": sessionId, "prompt": prompt])
            append(conversation, [
                "sessionUpdate": "lilo_turn_end", "stopReason": result["stopReason"] as? String ?? "end_turn",
                "at": Date().timeIntervalSince1970 * 1000
            ])
            save(conversation)
        } catch {
            conversation.lastError = error.localizedDescription
            // The agent's own sign-in, offered where it failed: a turn can need one long after the session opened.
            if (error as? ACPConnection.RPCError)?.code == -32000, !conversation.authMethods.isEmpty {
                append(conversation, ["sessionUpdate": "lilo_auth", "methods": conversation.authMethods.map { method in
                    ["id": method["id"] ?? "", "name": method["name"] ?? "", "description": method["description"] ?? NSNull()]
                }])
            }
            append(conversation, ["sessionUpdate": "lilo_error", "message": error.localizedDescription])
            setState(conversation, .failed)
            conversation.queued.removeAll()
            return
        }
        refreshDiff(conversation)
        if !conversation.queued.isEmpty {
            let next = conversation.queued.removeFirst()
            append(conversation, ["sessionUpdate": "lilo_queued", "count": conversation.queued.count])
            return await runTurn(conversation, blocks: next)
        }
        if !isShown(conversation.tabId) {
            conversation.unread = true
            postDoneNotification(conversation)
        }
        setState(conversation, .idle)
        scheduleIdleStop(conversation)
    }

    /// Signs in with one of the agent's methods: in a terminal tab for a `terminal` one, else through the agent.
    func authenticate(_ tabId: UUID, methodId: String) {
        guard let conversation = conversations[tabId],
              let method = conversation.authMethods.first(where: { $0["id"] as? String == methodId }) else { return }
        if method["type"] as? String == "terminal" {
            signInInTerminal(conversation, method: method)
            return
        }
        Task {
            do {
                try await ensureConnected(conversation)
                _ = try await conversation.connection?.request("authenticate", ["methodId": methodId])
                append(conversation, ["sessionUpdate": "lilo_notice", "notice": "signedIn"])
            } catch {
                append(conversation, ["sessionUpdate": "lilo_error", "message": error.localizedDescription])
            }
        }
    }

    /// The agent's process up and initialized, without opening a session: what signing in needs.
    private func ensureConnected(_ conversation: Conversation) async throws {
        if conversation.connection != nil { return }
        try await ensureStarted(conversation)
    }

    func cancel(_ tabId: UUID) {
        guard let conversation = conversations[tabId], let sessionId = conversation.sessionId else { return }
        if let permission = conversation.permission {
            conversation.connection?.respond(id: permission.id.value["id"] as Any, result: ["outcome": ["outcome": "cancelled"]])
            resolve(conversation, optionId: nil)
        }
        conversation.connection?.notify("session/cancel", ["sessionId": sessionId])
    }

    /// An agent with nothing to do stops after a while; one that cannot resume a session never does,
    /// or its conversation would lose what the agent remembers.
    private func scheduleIdleStop(_ conversation: Conversation) {
        conversation.idleStop?.cancel()
        guard conversation.canLoadSession else { return }
        let work = DispatchWorkItem { [weak self, weak conversation] in
            guard let self, let conversation, conversation.state == .idle, conversation.permission == nil,
                  conversation.queued.isEmpty else { return }
            Self.logger.info("stopping idle agent \(conversation.agentId, privacy: .public)")
            let connection = conversation.connection
            conversation.connection = nil
            connection?.terminate()
            self.scheduleSummary()
        }
        conversation.idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
    }

    func setMode(_ tabId: UUID, modeId: String) {
        guard let conversation = conversations[tabId], let sessionId = conversation.sessionId, let connection = conversation.connection else { return }
        Task {
            _ = try? await connection.request("session/set_mode", ["sessionId": sessionId, "modeId": modeId])
            append(conversation, ["sessionUpdate": "current_mode_update", "currentModeId": modeId])
        }
    }

    func setConfigOption(_ tabId: UUID, configId: String, value: Any) {
        guard let conversation = conversations[tabId], let sessionId = conversation.sessionId, let connection = conversation.connection else { return }
        Task {
            var params: [String: Any] = ["sessionId": sessionId, "configId": configId, "value": value]
            if value is Bool { params["type"] = "boolean" }
            guard let result = try? await connection.request("session/set_config_option", params),
                  let options = result["configOptions"] as? [Any] else { return }
            append(conversation, ["sessionUpdate": "config_option_update", "configOptions": options])
        }
    }

    // MARK: - What the agent sends

    private func receive(_ message: ACPConnection.Incoming, from conversation: Conversation) {
        switch message {
        case .notification(let method, let params):
            guard method == "session/update", let update = params["update"] as? [String: Any] else { return }
            if conversation.replaying { return }
            append(conversation, update)
            if conversation.state == .busy { keepAwake(conversation) }
            switch update["sessionUpdate"] as? String {
            case "session_info_update":
                if let title = update["title"] as? String, !title.isEmpty, title != conversation.title {
                    conversation.title = title
                    updateTab(conversation)
                    context?.windows.window(forTab: conversation.tabId)?.renameConversationFolder(conversation)
                }
            case "tool_call", "tool_call_update":
                if update["kind"] as? String == "edit" || update["kind"] as? String == "delete" || update["kind"] as? String == "move" {
                    refreshDiff(conversation)
                }
            default:
                break
            }
        case .request(let id, let method, let params):
            guard method == "session/request_permission" else {
                // Lilo offers neither file nor terminal access: the agent uses its own.
                conversation.connection?.respond(id: id, errorCode: -32601, message: "Method not found: \(method)")
                return
            }
            let requestId = UUID().uuidString
            conversation.permission = (ACPConnection.Payload(value: ["id": id]), requestId, params)
            append(conversation, [
                "sessionUpdate": "lilo_permission", "requestId": requestId,
                "toolCall": params["toolCall"] ?? [:], "options": params["options"] ?? []
            ])
            updateTab(conversation)
            if !isShown(conversation.tabId) { postPermissionNotification(conversation) }
        }
    }

    func answer(_ tabId: UUID, requestId: String, optionId: String?) {
        guard let conversation = conversations[tabId], let permission = conversation.permission, permission.requestId == requestId else { return }
        let outcome: [String: Any] = optionId.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        conversation.connection?.respond(id: permission.id.value["id"] as Any, result: ["outcome": outcome])
        resolve(conversation, optionId: optionId)
    }

    /// The option of the open permission request that has this kind (`allow_once`, `reject_once`...).
    func option(of tabId: UUID, kind: String) -> (requestId: String, optionId: String)? {
        guard let permission = conversations[tabId]?.permission,
              let options = permission.params["options"] as? [[String: Any]],
              let option = options.first(where: { $0["kind"] as? String == kind }),
              let optionId = option["optionId"] as? String else { return nil }
        return (permission.requestId, optionId)
    }

    private func resolve(_ conversation: Conversation, optionId: String?) {
        guard let permission = conversation.permission else { return }
        conversation.permission = nil
        append(conversation, ["sessionUpdate": "lilo_permission_resolved", "requestId": permission.requestId, "optionId": optionId ?? NSNull()])
        withdrawNotification(conversation.tabId)
        updateTab(conversation)
    }

    // MARK: - Checkpoints

    func restore(_ tabId: UUID, checkpoint index: Int) {
        guard let conversation = conversations[tabId], index < conversation.checkpoints.count,
              let tree = conversation.checkpoints[index] else { return }
        let cwd = conversation.cwd
        Task.detached(priority: .userInitiated) {
            let restored = ConversationCheckpoints.restore(tree, in: cwd)
            await MainActor.run { [weak self] in
                guard let self, let conversation = self.conversations[tabId] else { return }
                self.append(conversation, ["sessionUpdate": "lilo_notice", "notice": restored ? "restored" : "restoreFailed"])
                self.refreshDiff(conversation)
            }
        }
    }

    /// Puts one file back as it was before the prompt `index` was sent.
    func undo(_ tabId: UUID, path: String, checkpoint index: Int) {
        guard let conversation = conversations[tabId], index < conversation.checkpoints.count,
              let tree = conversation.checkpoints[index] else { return }
        let cwd = conversation.cwd
        Task.detached(priority: .userInitiated) {
            let undone = ConversationCheckpoints.restoreFile(path, from: tree, in: cwd)
            await MainActor.run { [weak self] in
                guard let self, let conversation = self.conversations[tabId] else { return }
                self.append(conversation, ["sessionUpdate": "lilo_undo", "path": path, "ok": undone])
                self.refreshDiff(conversation)
            }
        }
    }

    // MARK: - Tab row and overview

    /// A working agent keeps the Mac awake like a quiet command; marked every 10 s at most, not per streamed chunk.
    private func keepAwake(_ conversation: Conversation) {
        guard Date().timeIntervalSince(conversation.keptAwakeAt) > 10 else { return }
        conversation.keptAwakeAt = Date()
        context?.powerKeeper.browserAgentWorked(conversation.tabId)
    }

    private func setState(_ conversation: Conversation, _ state: State) {
        guard conversation.state != state else { return }
        conversation.state = state
        updateTab(conversation)
        if state == .busy { keepAwake(conversation) }
    }

    private func updateTab(_ conversation: Conversation) {
        scheduleSummary()
        guard let window = context?.windows.window(forTab: conversation.tabId) else { return }
        let updated = window.updateRuntimeTab(id: conversation.tabId) { tab in
            tab.terminalState = conversation.state.rawValue
            tab.awaitingInputSince = conversation.permission == nil ? nil : (tab.awaitingInputSince ?? Date())
            tab.hasUnreadOutput = conversation.unread
            if !conversation.title.isEmpty { tab.title = conversation.title }
        }
        if let updated { window.enqueueVisibleTabUpdate(updated) }
    }

    /// Lines the conversation changed in the project, since its first prompt: not what was uncommitted
    /// before it started. Once per second at most.
    private func refreshDiff(_ conversation: Conversation) {
        let tabId = conversation.tabId
        guard diffRefresh.insert(tabId).inserted else { return }
        let cwd = conversation.cwd
        let start = conversation.checkpoints.lazy.compactMap { $0 }.first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task.detached(priority: .utility) {
                let stat = start.flatMap { ConversationCheckpoints.stat(since: $0, in: cwd) }
                let branch = GitDiff.run(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd)
                    .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    guard let self else { return }
                    self.diffRefresh.remove(tabId)
                    guard let window = self.context?.windows.window(forTab: tabId),
                          let updated = window.updateRuntimeTab(id: tabId, mutate: { tab in
                              tab.diffAdded = stat?.added ?? 0
                              tab.diffRemoved = stat?.removed ?? 0
                              tab.gitBranch = branch
                          }) else { return }
                    window.enqueueVisibleTabUpdate(updated)
                    self.scheduleSummary()
                }
            }
        }
    }

    /// Every conversation, for the Agents badge and its popover, sent once per main-thread turn.
    private func scheduleSummary() {
        guard !summaryScheduled else { return }
        summaryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.summaryScheduled = false
            let payload = ["conversations": self.summaries()]
            for window in self.context?.windows.windows ?? [] {
                window.bridgeRouter.send(event: "conversationsChanged", data: payload)
            }
        }
    }

    func summaries() -> [[String: Any]] {
        conversations.values.compactMap { conversation in
            guard let spaceId = context?.browserState.durableTab(for: conversation.tabId)?.spaceId else { return nil }
            let space = context?.spaceManager?.space(with: spaceId)
            var summary: [String: Any] = [
                "tabId": conversation.tabId.uuidString,
                "agentId": conversation.agentId,
                "title": conversation.title,
                "state": conversation.state.rawValue,
                "unread": conversation.unread,
                "spaceId": spaceId.uuidString,
                "spaceName": space?.name ?? "",
                "running": conversation.connection != nil
            ]
            if let permission = conversation.permission {
                summary["permission"] = [
                    "requestId": permission.requestId,
                    "title": (permission.params["toolCall"] as? [String: Any])?["title"] as? String ?? "",
                    "options": permission.params["options"] ?? []
                ]
            }
            if let error = conversation.lastError { summary["error"] = error }
            return summary
        }
    }

    // MARK: - Notifications

    private func postPermissionNotification(_ conversation: Conversation) {
        guard let permission = conversation.permission else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation.title.isEmpty ? (catalog.agent(id: conversation.agentId)?.name ?? "Agent") : conversation.title
        content.body = (permission.params["toolCall"] as? [String: Any])?["title"] as? String ?? "Waiting for your answer".localized
        content.sound = .default
        content.threadIdentifier = conversation.tabId.uuidString
        content.categoryIdentifier = UNNotificationCategory.conversationPermission
        content.userInfo = ["conversationTabId": conversation.tabId.uuidString]
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: Self.notificationId(conversation.tabId), content: content, trigger: nil)
        )
    }

    private func postDoneNotification(_ conversation: Conversation) {
        guard context?.settingsStore?.get("agentsNotifyDone") != "false" else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation.title.isEmpty ? (catalog.agent(id: conversation.agentId)?.name ?? "Agent") : conversation.title
        content.body = "Done".localized
        content.threadIdentifier = conversation.tabId.uuidString
        content.userInfo = ["conversationTabId": conversation.tabId.uuidString]
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: Self.notificationId(conversation.tabId), content: content, trigger: nil)
        )
    }

    private func withdrawNotification(_ tabId: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId(tabId)])
    }

    private static func notificationId(_ tabId: UUID) -> String { "lilo.conversation.\(tabId.uuidString)" }
}
