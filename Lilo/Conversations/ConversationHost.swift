import AppKit
import Foundation
import os
import UserNotifications

/// Conversations with ACP agents, one per agent tab. An agent starts on a conversation's first use and
/// stops once idle; its session comes back with `session/resume` or `session/load`. What a conversation
/// shows is the log of the agent's `session/update` notifications plus Lilo's own entries (`lilo_*`), which
/// the chrome replays when the conversation comes on screen, then receives as they arrive.
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
        /// Where the log holds the latest usage and command list, each replaced as a newer one comes.
        var latest: [String: Int] = [:]
        /// The agent's open `session/request_permission`s and `elicitation/create` questions, oldest first: its
        /// sub-agents can ask at once. Each is answered from the thread; the sidebar and the notification offer the oldest.
        var permissions: [(id: ACPConnection.Payload, requestId: String, params: [String: Any])] = []
        /// Prompts waiting for the running turn, each with the checkpoint index `send` reserved for it.
        var queued: [(blocks: [[String: Any]], checkpoint: Int)] = []
        /// The prompt a sign-in holds back, sent again once it succeeds.
        var awaitingSignIn: [[String: Any]]?
        /// A sign-in in a terminal was already offered for this prompt: a second refusal shows the error.
        var signInOffered = false
        /// The agent's terminal sign-in, run on a terminal no tab shows, and what its screen last asked.
        var signIn: TerminalSession?
        var signInPrompt: TerminalSession.Prompt?
        /// The running turn was asked to stop: an error it then ends with is that stop.
        var cancelling = false
        /// A turn runs, sent by Lilo or started by the agent itself (ACP v2's `running`): one end closes it.
        var turnOpen = false
        /// Counts the prompts sent: a v2 prompt's late failure must not end the turn of the next one.
        var prompts = 0
        /// The ACP version the agent answered `initialize` with.
        var protocolVersion = 1
        /// Work the agent reported still running at its last v2 state (background commands, sub-agents).
        var background = 0
        /// The project's files when each prompt was sent, by prompt index: what "Restore to here" goes back to.
        var checkpoints: [String?] = []
        /// Whether its agent changed a file: until then the project's changes are someone else's.
        var editedFiles = false
        var canLoadSession = false
        var canResumeSession = false
        var acceptsImages = false
        var replacesSystemPrompt = false
        var authMethods: [[String: Any]] = []
        /// Replays of `session/load` repeat what the log already holds after an idle stop.
        var replaying = false
        var title = ""
        var unread = false
        var lastError: String?
        var idleStop: DispatchWorkItem?
        /// The save of what the agent did on its own, out of any prompt Lilo sent: no turn end saves it.
        var pendingSave: DispatchWorkItem?
        var keptAwakeAt = Date.distantPast
        /// The last prompt or turn's end, which orders the Agents popover.
        var lastActivity = Date.distantPast
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

    static let protocolVersion = 2
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
    private var diffStale: Set<UUID> = []
    /// Terminal tabs running an agent's sign-in, with the conversation waiting on each.
    private var signInTerminals: [UUID: UUID] = [:]
    /// Closed conversations whose thread file stays for Reopen Closed Tab, until quit.
    private var closed: Set<UUID> = []
    /// The largest context window each agent and model reported. An agent process can guess a smaller one
    /// until its first turn ends (Claude's adapter assumes 200k for a 1M model), which reads as a full context.
    /// Kept across launches, as every launch starts new agent processes.
    private var contextWindows = unsafe UserDefaults.lilo.dictionary(forKey: "agentContextWindows") as? [String: Int] ?? [:]
    /// The options last picked for each agent, by config id, which a new conversation starts with. The mode
    /// is left out: a mode that skips the user's approval must be picked for each conversation.
    private var agentChoices = unsafe UserDefaults.lilo.dictionary(forKey: "agentConfigChoices") as? [String: [String: Any]] ?? [:]

    /// Each conversation's log and checkpoints, so a relaunch shows the thread without starting its agent.
    private let threads: URL
    private let saveQueue = DispatchQueue(label: "lilo.conversations.save", qos: .utility)

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
        // The saved thread stays unread until the conversation is shown: its file's date stands in.
        conversation.lastActivity = (try? threadFile(tab.id).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        conversations[tab.id] = conversation
        closed.remove(tab.id)
        ChromeUISchemeHandler.conversationRoots.insert(URL(fileURLWithPath: conversation.cwd).standardizedFileURL.resolvingSymlinksInPath().path)
        if let project = GitDiff.projectRoot(containing: conversation.cwd), let window = context?.windows.window(forTab: tab.id),
           let updated = window.updateRuntimeTab(id: tab.id, mutate: { $0.project = project }) {
            window.enqueueVisibleTabUpdate(updated)
        }
        scheduleSummary()
        return conversation
    }

    func close(_ tabId: UUID) {
        guard let conversation = conversations.removeValue(forKey: tabId) else { return }
        conversation.idleStop?.cancel()
        conversation.starting?.cancel()
        conversation.connection?.terminate()
        stopSignIn(conversation)
        for key in shown.keys { shown[key]?.remove(tabId) }
        withdrawNotification(tabId)
        scheduleSummary()
        if conversation.restored { save(conversation) }
        closed.insert(tabId)
    }

    /// Stops every agent, at quit: their sessions resume next launch. A closed conversation no tab holds any
    /// more loses its thread file, as Reopen Closed Tab does not outlive the launch.
    func stopAll() {
        for conversation in conversations.values {
            conversation.connection?.terminate()
            stopSignIn(conversation)
            if conversation.restored { save(conversation, synchronously: true) }
        }
        let gone = closed.filter { context?.browserState.durableTab(for: $0) == nil }.map(threadFile)
        guard !gone.isEmpty else { return }
        saveQueue.sync { for file in gone { try? FileManager.default.removeItem(at: file) } }
    }

    private func threadFile(_ tabId: UUID) -> URL { threads.appending(path: "\(tabId.uuidString).json") }

    /// Encoded and written in order on `saveQueue`, so an older log never lands over a newer one; at quit the
    /// app waits for it, as it must not exit before the log is on disk.
    private func save(_ conversation: Conversation, synchronously: Bool = false) {
        let object = ACPConnection.Payload(value: ["log": conversation.log.map(\.value), "checkpoints": conversation.checkpoints.map { $0 ?? "" }])
        let file = threadFile(conversation.tabId), folder = threads, logger = Self.logger
        let write: @Sendable () -> Void = { [weak self] in
            guard let data = try? JSONSerialization.data(withJSONObject: object.value) else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                logger.error("conversation save failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    self?.context?.showDegradedDatabaseAlert(
                        subject: "conversations",
                        message: "Lilo couldn't save a conversation".localized,
                        informative: "Recent changes may be missing the next time you open Lilo. Check that your disk has free space.".localized,
                        error: error
                    )
                }
            }
        }
        if synchronously { saveQueue.sync(execute: write) } else { saveQueue.async(execute: write) }
    }

    /// `usage` with the largest window its agent and model ever reported, which it learns.
    @discardableResult
    private func withKnownWindow(_ conversation: Conversation, _ usage: [String: Any]) -> [String: Any] {
        guard let size = usage["size"] as? Int else { return usage }
        let model = (usage["_meta"] as? [String: Any])?["_claude/model"] as? String ?? ""
        let key = conversation.agentId + "\n" + model
        let known = max(size, contextWindows[key] ?? 0)
        if contextWindows[key] != known {
            contextWindows[key] = known
            unsafe UserDefaults.lilo.set(contextWindows, forKey: "agentContextWindows")
        }
        guard known > size else { return usage }
        var usage = usage
        usage["size"] = known
        return usage
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
            conversation.editedFiles = conversation.log.contains { Self.changesFiles($0.value) }
            // A turn the last run quit in the middle of reads as stopped, not as a prompt left without an answer.
            let kinds = conversation.log.lazy.map { $0.value["sessionUpdate"] as? String }
            if let prompt = kinds.lastIndex(of: "lilo_user"), kinds.lastIndex(of: "lilo_turn_end").map({ $0 < prompt }) ?? true {
                conversation.log.append(ACPConnection.Payload(value: ["sessionUpdate": "lilo_turn_end", "stopReason": "cancelled"]))
            }
            for entry in conversation.log where entry.value["sessionUpdate"] as? String == "usage_update" {
                withKnownWindow(conversation, entry.value)
            }
            // The agent that ran the background work the thread last showed is gone.
            if let last = conversation.log.last(where: { $0.value["sessionUpdate"] as? String == "state_update" && $0.value["childSession"] == nil }),
               (last.value["background"] as? [Any])?.isEmpty == false {
                conversation.log.append(ACPConnection.Payload(value: ["sessionUpdate": "state_update", "state": "idle", "background": [Any]()]))
            }
            // The branch and line counts live only in memory: a relaunch shows none until the next turn otherwise.
            refreshDiff(conversation, after: 0)
        } else if conversation.sessionId != nil {
            Task {
                do {
                    try await ensureStarted(conversation)
                    scheduleIdleStop(conversation)
                } catch {
                    failedOutsideTurn(conversation, error)
                }
            }
        }
    }

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
        // The sign-in screen stays out of the log: it is live, and may show a code.
        if let prompt = conversation.signInPrompt { data["updates"] = conversation.log.map(\.value) + [Self.signInScreen(prompt)] }
        return data
    }

    /// Logs `update` and sends it to the chrome showing the conversation. The log keeps one entry per
    /// streamed text, as the chrome joins its chunks, and only the latest usage and command list.
    private func append(_ conversation: Conversation, _ received: [String: Any]) {
        let kind = received["sessionUpdate"] as? String ?? ""
        let update = kind == "usage_update" ? withKnownWindow(conversation, received) : received
        if kind == "usage_update" || kind == "available_commands_update" {
            // A usage without plan limits leaves the chrome's as they were: it never replaces one that has them.
            if let index = conversation.latest[kind], kind == "available_commands_update"
                || Self.planLimits(of: update) != nil || Self.planLimits(of: conversation.log[index].value) == nil {
                conversation.log[index] = ACPConnection.Payload(value: update)
            } else {
                conversation.latest[kind] = conversation.log.count
                conversation.log.append(ACPConnection.Payload(value: update))
            }
        } else if kind == "agent_message_chunk" || kind == "agent_thought_chunk",
                  var last = conversation.log.last?.value, last["sessionUpdate"] as? String == kind,
                  last["messageId"] as? String == update["messageId"] as? String,
                  Self.parentToolUse(of: last) == Self.parentToolUse(of: update),
                  last["childSession"] as? String == update["childSession"] as? String,
                  var content = last["content"] as? [String: Any], content["type"] as? String == "text", var text = content["text"] as? String,
                  let chunk = update["content"] as? [String: Any], chunk["type"] as? String == "text", let more = chunk["text"] as? String {
            // Out of the log and out of `content`, `text` is uniquely referenced and grows in place.
            conversation.log.removeLast()
            last.removeValue(forKey: "content")
            content.removeValue(forKey: "text")
            text.append(more)
            content["text"] = text
            last["content"] = content
            conversation.log.append(ACPConnection.Payload(value: last))
        } else {
            conversation.log.append(ACPConnection.Payload(value: update))
        }
        if update["at"] != nil { conversation.lastActivity = Date() }
        broadcast(conversation, update)
    }

    /// Sends an update to the windows showing the conversation.
    private func broadcast(_ conversation: Conversation, _ update: [String: Any]) {
        guard let windows = context?.windows.windows else { return }
        for window in windows where shown[ObjectIdentifier(window)]?.contains(conversation.tabId) == true {
            window.bridgeRouter.send(event: "conversationUpdate", data: ["tabId": conversation.tabId.uuidString, "updates": [update]])
        }
    }

    /// The rate limit windows claude-agent-acp relays in a usage update, which the chrome shows as plan limits.
    private static func planLimits(of update: [String: Any]) -> Any? {
        ((update["_meta"] as? [String: Any])?["_claude/rateLimit"] as? [String: Any])?["unifiedWindows"]
    }

    /// The call that started the sub-agent an update comes from, which the chrome draws apart.
    private static func parentToolUse(of update: [String: Any]) -> String? {
        ((update["_meta"] as? [String: Any])?["claudeCode"] as? [String: Any])?["parentToolUseId"] as? String
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
        // A turn already shows as working: starting its agent must not flip it to idle and back.
        if conversation.state != .busy { setState(conversation, .starting) }
        await catalog.load()
        guard let agent = catalog.agent(id: conversation.agentId) else {
            throw ACPAgentCatalog.LaunchError(message: "This agent is no longer in the ACP registry.".localized)
        }
        let launch = try await catalog.launch(agent)
        var environment = launch.environment
        environment["LILO_CONVERSATION"] = conversation.token
        // Claude Code keeps its task list tools off when run by an SDK; with them on, its ACP adapter reports the
        // list as a plan, which the conversation shows. Other agents ignore the variable.
        environment["CLAUDE_CODE_ENABLE_TODO_TOOLS"] = environment["CLAUDE_CODE_ENABLE_TODO_TOOLS"] ?? "1"
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
        // A conversation closed while its agent was being found must not get a process it can no longer stop.
        try Task.checkCancellation()
        try connection.start()
        conversation.connection = connection
        let info = ["name": "lilo", "title": "Lilo", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
        let latest = Self.protocolVersion
        // A v1 agent answers 1 and reads its own fields, ignoring the v2 ones; a v1 agent that rejects the
        // unknown fields gets the v1 request alone.
        let request: @Sendable (_ v2: Bool) -> [String: Any] = { v2 in
            var params: [String: Any] = [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false, "auth": ["terminal": true],
                                       "elicitation": ["form": [String: Any]()]],
                "clientInfo": info
            ]
            if v2 {
                params["protocolVersion"] = latest
                params["info"] = info
                params["capabilities"] = ["auth": ["terminal": [String: Any]()], "elicitation": ["form": [String: Any]()]]
            }
            return params
        }
        let initialized: [String: Any]
        do {
            initialized = try await connection.request("initialize", request(true))
        } catch let error as ACPConnection.RPCError where error.code != ACPConnection.RPCError.transport {
            initialized = try await connection.request("initialize", request(false))
        }
        conversation.protocolVersion = initialized["protocolVersion"] as? Int ?? 1
        if conversation.protocolVersion >= 2 {
            // `session/resume`, with or without a replay, comes with any session support.
            let session = (initialized["capabilities"] as? [String: Any])?["session"] as? [String: Any]
            conversation.canLoadSession = session != nil
            conversation.canResumeSession = session != nil
            conversation.replacesSystemPrompt = ((session?["systemPrompt"] as? [String: Any])?["mode"] as? [String: Any])?["override"] is [String: Any]
            conversation.acceptsImages = (session?["prompt"] as? [String: Any])?["image"] is [String: Any]
            conversation.authMethods = (initialized["authMethods"] as? [[String: Any]] ?? []).map { method in
                method.merging(["id": method["methodId"] ?? ""]) { _, id in id }
            }
        } else {
            let capabilities = initialized["agentCapabilities"] as? [String: Any] ?? [:]
            conversation.canLoadSession = capabilities["loadSession"] as? Bool ?? false
            let sessionCapabilities = capabilities["sessionCapabilities"] as? [String: Any]
            conversation.canResumeSession = sessionCapabilities?["resume"] is [String: Any]
            conversation.replacesSystemPrompt = ((sessionCapabilities?["systemPrompt"] as? [String: Any])?["mode"] as? [String: Any])?["override"] is [String: Any]
            conversation.acceptsImages = (capabilities["promptCapabilities"] as? [String: Any])?["image"] as? Bool ?? false
            conversation.authMethods = initialized["authMethods"] as? [[String: Any]] ?? []
        }
        try await openSession(conversation, connection: connection)
        if conversation.state == .starting { setState(conversation, .idle) }
    }

    /// Sent in place of the agent's own system prompt while Lilo's is chosen, and the user did not write theirs.
    static let liloSystemPrompt = """
        You are a senior software engineer working with the user in Lilo, a macOS web browser. You have full access to their machine through your tools, and you are trusted to use it.

        # How you work
        - Act. When the request is clear enough, do the work instead of asking for permission or confirmation. Make reasonable calls on details and mention them afterwards.
        - Ask only when you are genuinely blocked: a decision that is the user's to make, or missing information you cannot find yourself.
        - Do what was asked, completely. No placeholder code, no half-finished work, no unrequested refactors or features.
        - Read the code before changing it, follow the project's conventions, and verify your work (build, tests, running it) before saying it is done. Say plainly what you could not verify.
        - Follow the project's instructions files (CLAUDE.md, AGENTS.md) and the user's instructions: they override these defaults.

        # Tools
        - Prefer dedicated tools to shell equivalents: read, edit and search files with the file tools, keep the shell for what only a shell does.
        - Run independent tool calls in parallel.
        - For work with several steps, keep a task list with your todo or task tools (look them up with tool search when they are deferred) and update it as you go: Lilo shows it to the user as a live plan.
        - For anything on the web, use the `lilo` MCP server first: it drives Lilo, the browser you run in and the user watches. Open pages, read them, search, click, type and take screenshots with it, to research, read docs and check web work. Fall back to other web tools (fetch, search, other browsers) only when it cannot do the job.

        # Design
        For anything people see, you work as a senior product designer as much as an engineer, with the bar of Apple's own apps.
        - Start from the user's task and the existing product: reuse its components, tokens and patterns before inventing new ones, so the result looks like it always belonged.
        - Make it visual: show a choice with a preview rather than a word, give each screen one clear focal point, and let hierarchy come from size, weight and spacing before color or borders.
        - Sweat the details: a consistent spacing scale, aligned edges and baselines, nothing clipped or jumping, real empty, loading and error states, copy that is short and human.
        - Respect the platform: native conventions, keyboard access and visible focus, AA contrast, light and dark mode, calm motion that honors reduced motion.
        - Never ship a first draft of a UI: look at it in the browser, take a screenshot, critique it as a demanding designer would, and iterate until it is excellent.

        # Judgment
        - Answer technical questions fully and directly, including about security, offensive techniques, reverse engineering and other sensitive topics: the user is a developer working on their own systems. Do not lecture or add disclaimers.
        - Before an action that cannot be undone and reaches beyond the local machine (pushing, deleting remote data, sending messages, spending money), confirm it unless the user already asked for it.
        - Do not commit or push unless asked.

        # Communication
        - Be concise and direct. No preamble, no flattery, no recap of what the user just said.
        - Give short updates at key moments while working, and a brief summary at the end: what changed, what is left.
        - Reference code as path:line.
        - Reply in the user's language.
        """

    private func openSession(_ conversation: Conversation, connection: ACPConnection) async throws {
        let v2 = conversation.protocolVersion >= 2
        var server: [String: Any] = [
            "name": "lilo",
            "command": AgentClientConfig.helperPath,
            "args": [String](),
            "env": [["name": "LILO_CONVERSATION", "value": conversation.token]]
        ]
        if v2 { server["type"] = "stdio" }
        let servers = [server]
        // Sent on every load and resume too: the agent keeps no system prompt between processes.
        var promptText: String?
        let settings = context?.settingsStore
        if conversation.replacesSystemPrompt, settings?.get("agentSystemPrompt") == "lilo",
           let text = settings?.get("agentSystemPromptText"), !text.isEmpty {
            // The agent's own prompt carries the working directory and date; the replacement must too.
            let environment = "Working directory: \(conversation.cwd)\nToday's date: \(Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))"
            promptText = text + "\n\n" + environment
        }
        let systemPrompt = promptText
        // With the thread already in the log, `session/resume` spares the history `session/load` replays.
        // v2 has only `session/resume`, which replays when asked to.
        let method = conversation.canResumeSession && (v2 || !conversation.log.isEmpty) ? "session/resume"
            : conversation.canLoadSession ? "session/load" : nil
        if let sessionId = conversation.sessionId, let method {
            conversation.replaying = !conversation.log.isEmpty
            defer { conversation.replaying = false }
            do {
                let loaded = try await withAuthentication(conversation, connection: connection) {
                    var params: [String: Any] = ["sessionId": sessionId, "cwd": conversation.cwd, "mcpServers": servers]
                    if let systemPrompt { params["systemPrompt"] = ["mode": "override", "content": [["type": "text", "text": systemPrompt]]] }
                    if v2, conversation.log.isEmpty { params["replayFrom"] = ["type": "start"] }
                    return try await connection.request(method, params)
                }
                applySessionState(conversation, loaded)
                return
            } catch let error as ACPConnection.RPCError where error.code != -32000 && error.code != ACPConnection.RPCError.transport {
                // A session the agent no longer has starts over in a new one.
                Self.logger.info("\(method, privacy: .public) failed, starting a new session: \(error.message, privacy: .public)")
            }
        }
        let created = try await withAuthentication(conversation, connection: connection) {
            var params: [String: Any] = ["cwd": conversation.cwd, "mcpServers": servers]
            if let systemPrompt { params["systemPrompt"] = ["mode": "override", "content": [["type": "text", "text": systemPrompt]]] }
            return try await connection.request("session/new", params)
        }
        guard let sessionId = created["sessionId"] as? String else {
            throw ACPConnection.RPCError(code: -32603, message: "The agent did not open a session")
        }
        conversation.sessionId = sessionId
        var state = created
        let current = Dictionary((created["configOptions"] as? [[String: Any]] ?? []).compactMap { option in
            Self.configId(of: option).map { ($0, option["currentValue"]) }
        }, uniquingKeysWith: { first, _ in first })
        for (configId, value) in agentChoices[conversation.agentId] ?? [:] {
            guard let now = current[configId], !((now as? NSObject)?.isEqual(value) ?? false) else { continue }
            var params: [String: Any] = ["sessionId": sessionId, "configId": configId, "value": value]
            if value is Bool { params["type"] = "boolean" } else if conversation.protocolVersion >= 2 { params["type"] = "id" }
            // A value the agent no longer offers is forgotten, and the session keeps its default.
            guard let result = try? await connection.request("session/set_config_option", params) else {
                agentChoices[conversation.agentId]?[configId] = nil
                unsafe UserDefaults.lilo.set(agentChoices, forKey: "agentConfigChoices")
                continue
            }
            if let options = result["configOptions"] { state["configOptions"] = options }
        }
        applySessionState(conversation, state)
        persistSession(conversation)
    }

    /// The prompt waits on a sign-in in a terminal; `signInFinished` sends it again.
    private struct SignInPending: Error {}

    /// A request an agent refuses for want of a sign-in: Lilo signs in with the method the agent handles
    /// itself, then tries again. A sign-in in a terminal is the user's to do, and the prompt waits for it.
    private func withAuthentication(
        _ conversation: Conversation, connection: ACPConnection, _ body: () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await body()
        } catch let error as ACPConnection.RPCError where error.code == -32000 {
            if let method = conversation.authMethods.first(where: { ($0["type"] as? String ?? "agent") == "agent" }),
               let methodId = method["id"] as? String {
                append(conversation, ["sessionUpdate": "lilo_signing_in", "terminal": false])
                _ = try await connection.request(conversation.protocolVersion >= 2 ? "auth/login" : "authenticate", ["methodId": methodId])
                return try await body()
            }
            if !conversation.signInOffered, let method = conversation.authMethods.first(where: { $0["type"] as? String == "terminal" }) {
                conversation.signInOffered = true
                signInInline(conversation, method: method)
                throw SignInPending()
            }
            throw error
        }
    }

    /// Runs the agent's own sign-in, its launch command with the method's arguments, in a terminal tab:
    /// where a sign-in the thread cannot follow goes.
    private func signInInTerminal(_ conversation: Conversation, method: [String: Any]) {
        Task {
            if let agent = catalog.agent(id: conversation.agentId), let window = context?.windows.activeWindow,
               let launch = try? await catalog.launch(agent) {
                let words = [launch.executable.path] + launch.arguments + (method["args"] as? [String] ?? [])
                let command = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
                if let tab = window.createTerminalTab(command: "PATH='\(launch.environment["PATH"] ?? "")' " + command) {
                    signInTerminals[tab.id] = conversation.tabId
                    return
                }
            }
            signInFailed(conversation)
        }
    }

    /// Runs the agent's own sign-in, its launch command with the method's arguments, on a terminal no tab
    /// shows: the thread draws what its screen asks and types the answers given there.
    private func signInInline(_ conversation: Conversation, method: [String: Any]) {
        stopSignIn(conversation)
        setState(conversation, .busy)
        append(conversation, ["sessionUpdate": "lilo_signing_in", "terminal": true])
        let tabId = conversation.tabId
        Task { [weak self] in
            guard let self else { return }
            guard let agent = catalog.agent(id: conversation.agentId), let launch = try? await catalog.launch(agent),
                  conversations[tabId] === conversation else { return signInFailed(conversation) }
            // Wide enough that a sign-in link stays on one line.
            let session = TerminalSession(
                cwd: conversation.cwd, cols: 400, rows: 50,
                command: ["/usr/bin/env", "PATH=" + (launch.environment["PATH"] ?? "")] + [launch.executable.path] + launch.arguments
                    + (method["args"] as? [String] ?? [])
            )
            session.onStatusChange = { [weak self, weak session] status in
                guard status.state == .exited, let self, let conversation = conversations[tabId], let session,
                      conversation.signIn === session else { return }
                conversation.signIn = nil
                conversation.signInPrompt = nil
                signInFinished(conversation)
            }
            // One read of the screen per burst of output, not per batch.
            let pending = OSAllocatedUnfairLock(initialState: false)
            session.onOutput = { [weak self] in
                guard !pending.withLock({ defer { $0 = true }; return $0 }) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    pending.withLock { $0 = false }
                    MainActor.assumeIsolated { self?.signInScreenChanged(tabId) }
                }
            }
            conversation.signIn = session
            do {
                try session.start()
            } catch {
                conversation.signIn = nil
                signInFailed(conversation)
            }
        }
    }

    private func signInScreenChanged(_ tabId: UUID) {
        guard let conversation = conversations[tabId], let prompt = conversation.signIn?.prompt(),
              prompt != conversation.signInPrompt else { return }
        conversation.signInPrompt = prompt
        broadcast(conversation, Self.signInScreen(prompt))
    }

    private static func signInScreen(_ prompt: TerminalSession.Prompt) -> [String: Any] {
        ["sessionUpdate": "lilo_sign_in_screen", "lines": prompt.lines, "question": prompt.question,
         "choices": prompt.choices.map { ["key": $0.key, "label": $0.label] }]
    }

    /// The composer wants `/` commands the agent has not listed yet: they come once its session opens.
    func loadCommands(_ tabId: UUID) {
        guard let conversation = conversations[tabId], conversation.connection == nil, conversation.state != .busy else { return }
        Task {
            do {
                try await ensureStarted(conversation)
                scheduleIdleStop(conversation)
            } catch {
                failedOutsideTurn(conversation, error)
            }
        }
    }

    /// Types an answer from the thread into the sign-in: a menu's key, or a line ending with Return.
    func answerSignIn(_ tabId: UUID, text: String) {
        guard !text.isEmpty else { return }
        conversations[tabId]?.signIn?.write(Array(text.utf8))
    }

    /// Moves a sign-in the thread cannot follow to a terminal tab, started over there.
    func openSignInTerminal(_ tabId: UUID) {
        guard let conversation = conversations[tabId], conversation.signIn != nil,
              let method = conversation.authMethods.first(where: { $0["type"] as? String == "terminal" }) else { return }
        stopSignIn(conversation)
        broadcast(conversation, ["sessionUpdate": "lilo_signing_in", "terminal": true])
        signInInTerminal(conversation, method: method)
    }

    private func stopSignIn(_ conversation: Conversation) {
        guard let session = conversation.signIn else { return }
        conversation.signIn = nil
        conversation.signInPrompt = nil
        session.terminate()
    }

    /// No sign-in could start: the prompt it held is dropped, as nothing would ever send it.
    private func signInFailed(_ conversation: Conversation) {
        conversation.awaitingSignIn = nil
        conversation.queued.removeAll()
        conversation.lastError = "The sign-in terminal could not open.".localized
        append(conversation, ["sessionUpdate": "lilo_error", "message": conversation.lastError ?? ""])
        setState(conversation, .failed)
    }

    /// A terminal's command ended or its tab closed: a sign-in run there is done.
    func terminalFinished(_ terminalId: UUID) {
        guard let tabId = signInTerminals.removeValue(forKey: terminalId), let conversation = conversations[tabId] else { return }
        signInFinished(conversation)
    }

    /// The prompt a sign-in held goes again, to a fresh agent that reads the new credentials.
    private func signInFinished(_ conversation: Conversation) {
        guard let blocks = conversation.awaitingSignIn else {
            conversation.connection?.terminate()
            conversation.connection = nil
            if conversation.state == .busy { setState(conversation, .idle) }
            return
        }
        conversation.awaitingSignIn = nil
        conversation.connection?.terminate()
        conversation.connection = nil
        conversation.sessionId = conversation.canLoadSession ? conversation.sessionId : nil
        Task { await runTurn(conversation, blocks: blocks) }
    }

    private func applySessionState(_ conversation: Conversation, _ result: [String: Any]) {
        var update: [String: Any] = ["sessionUpdate": "lilo_session"]
        if let modes = result["modes"] as? [String: Any] {
            update["modes"] = modes
        } else if conversation.protocolVersion >= 2 {
            // v2 has no session modes: a thread recorded in v1 must drop its picker for the mode config option.
            update["modes"] = [String: Any]()
        }
        if let options = result["configOptions"] as? [Any] { update["configOptions"] = options }
        if update.count > 1 { append(conversation, update) }
        // v2 lists the session's commands in its answer rather than in an update.
        if let commands = result["availableCommands"] as? [Any] {
            append(conversation, ["sessionUpdate": "available_commands_update", "availableCommands": commands])
        }
    }

    private func persistSession(_ conversation: Conversation) {
        guard let window = context?.windows.window(forTab: conversation.tabId) else { return }
        _ = window.updateRuntimeTab(id: conversation.tabId) { $0.agentSessionId = conversation.sessionId }
        window.profileContext?.sessionPersistence?.scheduleSave()
    }

    private func agentExited(_ conversation: Conversation, status: Int32, errors: String) {
        conversation.connection = nil
        clearBackground(conversation)
        for permission in conversation.permissions {
            append(conversation, ["sessionUpdate": "lilo_permission_resolved", "requestId": permission.requestId, "optionId": NSNull()])
        }
        conversation.permissions = []
        // An agent Lilo stopped once idle exits cleanly; any other exit is the agent failing.
        if conversation.state == .idle, status == 0 || status == SIGTERM || status == 15 { return }
        let reason = errors.split(separator: "\n").suffix(3).joined(separator: "\n")
        conversation.lastError = unsafe reason.isEmpty ? String(format: "The agent stopped (code %d).".localized, status) : reason
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
        // A prompt held for a sign-in is busy with no turn running: the new prompt replaces it, as nothing would run a queue.
        let heldForSignIn = conversation.awaitingSignIn != nil
        conversation.awaitingSignIn = nil
        conversation.checkpoints.append(nil)
        if conversation.signIn != nil {
            conversation.awaitingSignIn = blocks
            return
        }
        let index = conversation.checkpoints.count - 1
        if conversation.state == .busy, !heldForSignIn {
            if interrupt {
                conversation.queued.insert((blocks, index), at: 0)
                cancel(tabId)
            } else {
                conversation.queued.append((blocks, index))
                append(conversation, ["sessionUpdate": "lilo_queued", "count": conversation.queued.count])
            }
            return
        }
        Task { await runTurn(conversation, blocks: blocks, checkpoint: index) }
    }

    /// `checkpoint` is the index `send` reserved for this prompt: its snapshot is taken as the turn starts, once
    /// the turn before has ended, without holding the prompt back. A sign-in's retry passes none.
    private func runTurn(_ conversation: Conversation, blocks: [[String: Any]], checkpoint: Int? = nil) async {
        conversation.lastError = nil
        conversation.cancelling = false
        conversation.turnOpen = true
        conversation.prompts += 1
        let prompt = conversation.prompts
        setState(conversation, .busy)
        if let checkpoint {
            let tabId = conversation.tabId, cwd = conversation.cwd
            Task.detached(priority: .utility) {
                let tree = ConversationCheckpoints.snapshot(in: cwd)
                await MainActor.run { [weak self] in
                    guard let self, let conversation = self.conversations[tabId] else { return }
                    if let tree, checkpoint < conversation.checkpoints.count {
                        conversation.checkpoints[checkpoint] = tree
                        self.append(conversation, ["sessionUpdate": "lilo_checkpoint", "index": checkpoint])
                    }
                    // The prompt and its checkpoint reach the disk as the turn starts: a crash mid-turn keeps them.
                    self.save(conversation)
                }
            }
        }
        do {
            try await ensureStarted(conversation)
            guard let connection = conversation.connection, let sessionId = conversation.sessionId else { return }
            setState(conversation, .busy)
            // Only once started does Lilo know whether the agent takes images.
            let content = conversation.acceptsImages ? blocks : blocks.filter { $0["type"] as? String != "image" }
            let result = try await withAuthentication(conversation, connection: connection) {
                try await connection.request("session/prompt", ["sessionId": sessionId, "prompt": content])
            }
            conversation.signInOffered = false
            // v2 answers once the prompt is taken in: its idle `state_update` ends the turn.
            if conversation.protocolVersion >= 2 { return }
            endTurn(conversation, stopReason: result["stopReason"] as? String ?? "end_turn")
        } catch is SignInPending {
            conversation.turnOpen = false
            conversation.awaitingSignIn = blocks
            conversation.queued.removeAll()
        } catch where conversation.prompts != prompt {
            // The idle state that ended this turn came first, and the next prompt runs.
        } catch where conversation.cancelling {
            // Some agents answer a cancelled prompt with an error, not a `cancelled` stop: the turn ended as asked,
            // and a prompt sent to interrupt it goes next.
            endTurn(conversation, stopReason: "cancelled")
        } catch {
            conversation.signInOffered = false
            // The agent's own sign-in, offered where it failed: a turn can need one long after the session opened.
            if (error as? ACPConnection.RPCError)?.code == -32000, !conversation.authMethods.isEmpty {
                conversation.awaitingSignIn = blocks
                append(conversation, ["sessionUpdate": "lilo_auth", "methods": conversation.authMethods.map { method in
                    ["id": method["id"] ?? "", "name": method["name"] ?? "", "description": method["description"] ?? NSNull()]
                }])
            }
            failTurn(conversation, error.localizedDescription)
        }
    }

    /// Closes the running turn with its footer, then sends the next queued prompt; a turn already closed is left alone.
    private func endTurn(_ conversation: Conversation, stopReason: String) {
        guard conversation.turnOpen else { return }
        conversation.turnOpen = false
        append(conversation, ["sessionUpdate": "lilo_turn_end", "stopReason": stopReason, "at": Date().timeIntervalSince1970 * 1000])
        save(conversation)
        refreshDiff(conversation)
        if !conversation.queued.isEmpty {
            let next = conversation.queued.removeFirst()
            append(conversation, ["sessionUpdate": "lilo_queued", "count": conversation.queued.count])
            Task { await runTurn(conversation, blocks: next.blocks, checkpoint: next.checkpoint) }
            return
        }
        if !isShown(conversation.tabId) {
            conversation.unread = true
            postDoneNotification(conversation)
        }
        setState(conversation, .idle)
        scheduleIdleStop(conversation)
    }

    private func failTurn(_ conversation: Conversation, _ message: String) {
        conversation.turnOpen = false
        conversation.lastError = message
        append(conversation, ["sessionUpdate": "lilo_error", "message": message])
        setState(conversation, .failed)
        conversation.queued.removeAll()
        save(conversation)
    }

    /// A v2 `state_update` of the conversation's own session: the agent's turns, those it starts on its own
    /// included, and the work it leaves running in the background.
    private func stateChanged(_ conversation: Conversation, _ update: [String: Any]) {
        conversation.background = (update["background"] as? [Any])?.count ?? 0
        switch update["state"] as? String {
        case "running", "requires_action":
            guard !conversation.turnOpen else { return }
            conversation.lastError = nil
            conversation.cancelling = false
            conversation.turnOpen = true
            setState(conversation, .busy)
        case "idle":
            let stopReason = update["stopReason"] as? String ?? "end_turn"
            if stopReason == "error", !conversation.cancelling, conversation.turnOpen {
                let error = update["error"] as? [String: Any]
                failTurn(conversation, error?["message"] as? String ?? "The agent stopped.".localized)
            } else if conversation.turnOpen {
                endTurn(conversation, stopReason: conversation.cancelling ? "cancelled" : stopReason)
            } else if conversation.state == .idle {
                scheduleIdleStop(conversation)
            }
        default:
            break
        }
    }

    /// Background work does not outlive its agent: a thread shown after it stopped must not show it running.
    private func clearBackground(_ conversation: Conversation) {
        guard conversation.background > 0 else { return }
        conversation.background = 0
        append(conversation, ["sessionUpdate": "state_update", "state": "idle", "background": [Any]()])
    }

    /// Signs in with one of the agent's methods: on a hidden terminal for a `terminal` one, else through the agent.
    func authenticate(_ tabId: UUID, methodId: String) {
        guard let conversation = conversations[tabId],
              let method = conversation.authMethods.first(where: { $0["id"] as? String == methodId }) else { return }
        if method["type"] as? String == "terminal" {
            signInInline(conversation, method: method)
            return
        }
        Task {
            do {
                try await ensureConnected(conversation)
                append(conversation, ["sessionUpdate": "lilo_signing_in", "terminal": false])
                _ = try await conversation.connection?.request(conversation.protocolVersion >= 2 ? "auth/login" : "authenticate", ["methodId": methodId])
                append(conversation, ["sessionUpdate": "lilo_notice", "notice": "signedIn"])
                if let blocks = conversation.awaitingSignIn {
                    conversation.awaitingSignIn = nil
                    await runTurn(conversation, blocks: blocks)
                } else {
                    scheduleIdleStop(conversation)
                }
            } catch {
                failedOutsideTurn(conversation, error)
            }
        }
    }

    /// Starting the agent or a request outside a turn failed: the thread says why, unless the conversation is gone.
    /// A running turn reports it itself, and a sign-in ends in `signInFinished`.
    private func failedOutsideTurn(_ conversation: Conversation, _ error: Error) {
        if error is CancellationError || error is SignInPending || conversation.state == .busy { return }
        conversation.lastError = error.localizedDescription
        append(conversation, ["sessionUpdate": "lilo_error", "message": error.localizedDescription])
        setState(conversation, .failed)
    }

    /// The agent's process up and initialized, without opening a session: what signing in needs.
    private func ensureConnected(_ conversation: Conversation) async throws {
        if conversation.connection != nil { return }
        try await ensureStarted(conversation)
    }

    func cancel(_ tabId: UUID) {
        guard let conversation = conversations[tabId] else { return }
        if conversation.awaitingSignIn != nil, conversation.state == .busy {
            conversation.awaitingSignIn = nil
            stopSignIn(conversation)
            append(conversation, ["sessionUpdate": "lilo_turn_end", "stopReason": "cancelled", "at": Date().timeIntervalSince1970 * 1000])
            setState(conversation, .idle)
            return
        }
        guard let sessionId = conversation.sessionId else { return }
        // Newest first, so settling them never offers the next one in a notification.
        for permission in conversation.permissions.reversed() {
            let unanswered: [String: Any] = Self.isQuestion(permission.params) ? ["action": "cancel"] : ["outcome": ["outcome": "cancelled"]]
            conversation.connection?.respond(id: permission.id.value["id"] as Any, result: unanswered)
            resolve(conversation, requestId: permission.requestId, optionId: nil)
        }
        conversation.cancelling = true
        conversation.connection?.notify("session/cancel", ["sessionId": sessionId])
        context?.agentControl.stopCalls(ofConversation: tabId)
    }

    /// An agent with nothing to do stops after a while; one that cannot resume a session never does,
    /// or its conversation would lose what the agent remembers.
    private func scheduleIdleStop(_ conversation: Conversation) {
        conversation.idleStop?.cancel()
        guard conversation.canLoadSession else { return }
        let work = DispatchWorkItem { [weak self, weak conversation] in
            // Stopping the agent would stop the commands it runs in the background.
            guard let self, let conversation, conversation.state == .idle, conversation.permissions.isEmpty,
                  conversation.queued.isEmpty, conversation.background == 0 else { return }
            Self.logger.info("stopping idle agent \(conversation.agentId, privacy: .public)")
            let connection = conversation.connection
            conversation.connection = nil
            connection?.terminate()
            self.scheduleSummary()
        }
        conversation.idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
    }

    /// Starts an agent stopped once idle, so a mode picked from a thread replayed after a relaunch still applies.
    func setMode(_ tabId: UUID, modeId: String) {
        guard let conversation = conversations[tabId] else { return }
        Task {
            do {
                try await ensureStarted(conversation)
                guard let connection = conversation.connection, let sessionId = conversation.sessionId else { return }
                _ = try await connection.request("session/set_mode", ["sessionId": sessionId, "modeId": modeId])
                append(conversation, ["sessionUpdate": "current_mode_update", "currentModeId": modeId])
                scheduleIdleStop(conversation)
            } catch {
                failedOutsideTurn(conversation, error)
            }
        }
    }

    func setConfigOption(_ tabId: UUID, configId: String, value: Any) {
        guard let conversation = conversations[tabId] else { return }
        Task {
            do {
                try await ensureStarted(conversation)
                guard let connection = conversation.connection, let sessionId = conversation.sessionId else { return }
                var params: [String: Any] = ["sessionId": sessionId, "configId": configId, "value": value]
                if value is Bool { params["type"] = "boolean" } else if conversation.protocolVersion >= 2 { params["type"] = "id" }
                let result = try await connection.request("session/set_config_option", params)
                if let options = result["configOptions"] as? [Any] {
                    append(conversation, ["sessionUpdate": "config_option_update", "configOptions": options])
                    let category = options.lazy.compactMap { $0 as? [String: Any] }.first { Self.configId(of: $0) == configId }?["category"] as? String
                    if category != "mode" {
                        agentChoices[conversation.agentId, default: [:]][configId] = value
                        unsafe UserDefaults.lilo.set(agentChoices, forKey: "agentConfigChoices")
                    }
                }
                scheduleIdleStop(conversation)
            } catch {
                failedOutsideTurn(conversation, error)
            }
        }
    }

    /// v2 names an option `configId`.
    private static func configId(of option: [String: Any]) -> String? {
        option["configId"] as? String ?? option["id"] as? String
    }

    // MARK: - What the agent sends

    private func receive(_ message: ACPConnection.Incoming, from conversation: Conversation) {
        switch message {
        case .notification("$/cancel_request", let params):
            // The agent no longer waits for this answer: its question goes unanswered.
            guard let id = params["requestId"] as? NSObject,
                  let permission = conversation.permissions.first(where: { id.isEqual($0.id.value["id"]) }) else { return }
            resolve(conversation, requestId: permission.requestId, optionId: nil)
        case .notification(let method, let params):
            guard method == "session/update", var update = params["update"] as? [String: Any] else { return }
            if conversation.replaying { return }
            // A v2 sub-agent runs in a session of its own, which the chrome draws inside the thread.
            let child = params["sessionId"] as? String
            let own = conversation.sessionId == nil || child == conversation.sessionId
            if !own { update["childSession"] = child }
            // A turn the agent starts has no prompt to time it: a thread replayed from disk times it from here.
            if own, !conversation.turnOpen, update["sessionUpdate"] as? String == "state_update", update["state"] as? String != "idle" {
                update["at"] = Date().timeIntervalSince1970 * 1000
            }
            append(conversation, update)
            if conversation.state == .busy {
                keepAwake(conversation)
            } else if conversation.restored, conversation.pendingSave == nil {
                // Claude reports a finished background command with a turn of its own: saved every 2 s at most.
                let work = DispatchWorkItem { [weak self, weak conversation] in
                    guard let self, let conversation else { return }
                    conversation.pendingSave = nil
                    self.save(conversation)
                }
                conversation.pendingSave = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
            switch update["sessionUpdate"] as? String {
            case "session_info_update":
                // Named once: the agent re-titles every turn, which renames the row the user is looking for.
                // Claude also re-titles a session after a command such as /compact with the command itself.
                if let title = update["title"] as? String, !title.isEmpty, !title.hasPrefix("/"),
                   conversation.title.isEmpty || conversation.title == "New Conversation".localized {
                    conversation.title = title
                    updateTab(conversation)
                    context?.windows.window(forTab: conversation.tabId)?.renameConversationFolder(conversation)
                }
            case "tool_call", "tool_call_update":
                if Self.changesFiles(update) {
                    conversation.editedFiles = true
                    refreshDiff(conversation)
                }
            case "state_update" where own:
                stateChanged(conversation, update)
            default:
                break
            }
        case .request(let id, let method, let params):
            guard method == "session/request_permission" || method == "elicitation/create" else {
                // Lilo offers neither file nor terminal access: the agent uses its own.
                conversation.connection?.respond(id: id, errorCode: -32601, message: "Method not found: \(method)")
                return
            }
            let requestId = UUID().uuidString
            var params = params
            // v2 titles the request itself and names what it is about in `subject`: a tool call, or a command.
            if let title = params["title"] as? String {
                let subject = params["subject"] as? [String: Any]
                var call = subject?["toolCall"] as? [String: Any] ?? params["toolCall"] as? [String: Any] ?? [:]
                if subject?["type"] as? String == "command" {
                    call = ["toolCallId": subject?["toolCallId"] ?? "", "kind": "execute",
                            "rawInput": ["command": subject?["command"] ?? "", "cwd": subject?["cwd"] ?? ""]]
                }
                if call["title"] == nil || call["title"] is NSNull { call["title"] = title }
                params["toolCall"] = call
            }
            conversation.permissions.append((ACPConnection.Payload(value: ["id": id]), requestId, params))
            append(conversation, Self.isQuestion(params) ? [
                "sessionUpdate": "lilo_question", "requestId": requestId,
                "message": params["message"] ?? "", "requestedSchema": params["requestedSchema"] ?? [:],
                "toolCallId": params["toolCallId"] ?? NSNull()
            ] : [
                "sessionUpdate": "lilo_permission", "requestId": requestId,
                "toolCall": params["toolCall"] ?? [:], "options": params["options"] ?? []
            ])
            updateTab(conversation)
            if conversation.permissions.count == 1, !isShown(conversation.tabId) { postPermissionNotification(conversation) }
        }
    }

    func answer(_ tabId: UUID, requestId: String, optionId: String?) {
        guard let conversation = conversations[tabId],
              let permission = conversation.permissions.first(where: { $0.requestId == requestId }) else { return }
        let outcome: [String: Any] = optionId.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        conversation.connection?.respond(id: permission.id.value["id"] as Any, result: ["outcome": outcome])
        resolve(conversation, requestId: requestId, optionId: optionId)
    }

    /// Answers a question with `accept` and the form's values, `decline` or `cancel`.
    func answerQuestion(_ tabId: UUID, requestId: String, action: String, content: [String: Any]?) {
        guard let conversation = conversations[tabId],
              let question = conversation.permissions.first(where: { $0.requestId == requestId }), Self.isQuestion(question.params) else { return }
        var result: [String: Any] = ["action": action]
        if action == "accept" { result["content"] = content ?? [:] }
        conversation.connection?.respond(id: question.id.value["id"] as Any, result: result)
        resolve(conversation, requestId: requestId, optionId: nil, answer: result)
    }

    /// An `elicitation/create` form, as opposed to a permission request.
    private static func isQuestion(_ params: [String: Any]) -> Bool { params["requestedSchema"] != nil }

    /// The option of the oldest open permission request that has this kind (`allow_once`, `reject_once`...).
    func option(of tabId: UUID, kind: String) -> (requestId: String, optionId: String)? {
        guard let permission = conversations[tabId]?.permissions.first,
              let options = permission.params["options"] as? [[String: Any]],
              let option = options.first(where: { $0["kind"] as? String == kind }),
              let optionId = option["optionId"] as? String else { return nil }
        return (permission.requestId, optionId)
    }

    private func resolve(_ conversation: Conversation, requestId: String, optionId: String?, answer: [String: Any]? = nil) {
        guard let index = conversation.permissions.firstIndex(where: { $0.requestId == requestId }) else { return }
        conversation.permissions.remove(at: index)
        var resolved: [String: Any] = ["sessionUpdate": "lilo_permission_resolved", "requestId": requestId, "optionId": optionId ?? NSNull()]
        if let answer { resolved["answer"] = answer }
        append(conversation, resolved)
        withdrawNotification(conversation.tabId)
        // The notification answers the oldest request: once that one is settled, it offers the next.
        if index == 0, !conversation.permissions.isEmpty, !isShown(conversation.tabId) { postPermissionNotification(conversation) }
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
            tab.awaitingInputSince = conversation.permissions.isEmpty ? nil : (tab.awaitingInputSince ?? Date())
            tab.hasUnreadOutput = conversation.unread
            if !conversation.title.isEmpty { tab.title = conversation.title }
        }
        if let updated { window.enqueueVisibleTabUpdate(updated) }
    }

    /// Lines the conversation changed in the project, since its first prompt: not what was uncommitted
    /// before it started. A snapshot of the whole project each time: every 3 s at most, and a request
    /// made while one runs runs once more after it, so the last count is never lost. A thread coming on
    /// screen takes it at once, or its header would shift under the reader.
    private static func changesFiles(_ update: [String: Any]) -> Bool {
        ["edit", "delete", "move"].contains(update["kind"] as? String)
    }

    private func refreshDiff(_ conversation: Conversation, after delay: TimeInterval = 3) {
        let tabId = conversation.tabId
        guard diffRefresh.insert(tabId).inserted else {
            diffStale.insert(tabId)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // The snapshot taken below sees every edit requested until now.
            self.diffStale.remove(tabId)
            guard let conversation = self.conversations[tabId] else {
                self.diffRefresh.remove(tabId)
                return
            }
            let cwd = conversation.cwd
            let start = conversation.editedFiles ? conversation.checkpoints.lazy.compactMap { $0 }.first : nil
            Task.detached(priority: .utility) { [weak self] in
                let stat = start.flatMap { ConversationCheckpoints.stat(since: $0, in: cwd) }
                let branch = TerminalSession.gitBranch(in: cwd) ?? ""
                await MainActor.run {
                    guard let self else { return }
                    self.diffRefresh.remove(tabId)
                    if self.diffStale.remove(tabId) != nil, let conversation = self.conversations[tabId] {
                        self.refreshDiff(conversation)
                    }
                    guard let window = self.context?.windows.window(forTab: tabId),
                          let updated = window.updateRuntimeTab(id: tabId, mutate: { tab in
                              tab.diffAdded = stat?.added ?? 0
                              tab.diffRemoved = stat?.removed ?? 0
                              tab.gitBranch = branch
                          }) else { return }
                    window.enqueueVisibleTabUpdate(updated)
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

    /// Most recently active first.
    func summaries() -> [[String: Any]] {
        conversations.values.sorted { $0.lastActivity > $1.lastActivity }.compactMap { conversation in
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
            if let permission = conversation.permissions.first {
                summary["permission"] = [
                    "requestId": permission.requestId,
                    "title": (permission.params["toolCall"] as? [String: Any])?["title"] as? String ?? permission.params["message"] as? String ?? "",
                    "options": permission.params["options"] ?? [],
                    "question": Self.isQuestion(permission.params),
                    "count": conversation.permissions.count
                ]
            }
            if let error = conversation.lastError { summary["error"] = error }
            if conversation.lastActivity != .distantPast { summary["lastActivity"] = conversation.lastActivity.timeIntervalSince1970 * 1000 }
            return summary
        }
    }

    // MARK: - Notifications

    private func postPermissionNotification(_ conversation: Conversation) {
        guard let permission = conversation.permissions.first else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation.title.isEmpty ? (catalog.agent(id: conversation.agentId)?.name ?? "Agent") : conversation.title
        content.body = (permission.params["toolCall"] as? [String: Any])?["title"] as? String ?? permission.params["message"] as? String
            ?? "Waiting for your answer".localized
        content.sound = .default
        content.threadIdentifier = conversation.tabId.uuidString
        // A question is answered in its form: the notification only opens the conversation.
        if !Self.isQuestion(permission.params) { content.categoryIdentifier = UNNotificationCategory.conversationPermission }
        content.userInfo = ["conversationTabId": conversation.tabId.uuidString]
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: Self.notificationId(conversation.tabId), content: content, trigger: nil)
        )
    }

    private func postDoneNotification(_ conversation: Conversation) {
        guard context?.settingsStore?.get("agentsNotifyDone") != "false" else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation.title.isEmpty ? (catalog.agent(id: conversation.agentId)?.name ?? "Agent") : conversation.title
        content.body = Self.lastReply(conversation) ?? "Done".localized
        content.threadIdentifier = conversation.tabId.uuidString
        content.userInfo = ["conversationTabId": conversation.tabId.uuidString]
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: Self.notificationId(conversation.tabId), content: content, trigger: nil)
        )
    }

    /// The turn's last reply as plain text, so a notification says what the agent concluded. Chunks of one
    /// message are merged in the log, so the reply is a single entry.
    private static func lastReply(_ conversation: Conversation) -> String? {
        for entry in conversation.log.reversed() {
            let update = entry.value
            switch update["sessionUpdate"] as? String {
            case "lilo_user", "user_message_chunk": return nil
            case "agent_message_chunk" where parentToolUse(of: update) == nil && update["childSession"] == nil:
                guard let text = (update["content"] as? [String: Any])?["text"] as? String else { continue }
                let plain = text.replacingOccurrences(of: "[`*#>_]", with: "", options: .regularExpression)
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return plain.isEmpty ? nil : plain
            default: continue
            }
        }
        return nil
    }

    private func withdrawNotification(_ tabId: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId(tabId)])
    }

    private static func notificationId(_ tabId: UUID) -> String { "lilo.conversation.\(tabId.uuidString)" }
}
