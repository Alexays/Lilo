import AppKit
import Security
import WebKit
import os

/// Lets local AI agents drive Lilo over MCP: one session per socket connection.
@MainActor
final class AgentControl {
    static let defaultSocketURL = URL(fileURLWithPath: BuildIdentity.appSupportDirectory).appending(path: "agent.sock")

    private static let logger = Logger(liloCategory: "agent-control")
    let socketURL: URL
    private(set) weak var context: BrowserContext?
    private var server: AgentSocketServer?
    private(set) var sessions: [AgentSession] = []
    /// Agents spaces emptied of past conversations' folders this run: each once, before the first agent works there.
    var cleanedAgentsSpaceIds: Set<UUID> = []
    /// How long a dropped connection's session waits for lilo-mcp to reconnect (it tries for 30 seconds) before
    /// its tabs go.
    static var reconnectGrace: Duration = .seconds(35)
    /// How long the question letting a client in waits for the user: long enough to come back to the Mac, as the
    /// client is told it waits, so nothing times out meanwhile.
    static var connectionConsentTimeout: TimeInterval = 600
    /// Chrome-style integer ids for tabs, stable for the app's lifetime.
    var tabNumbers: [UUID: Int] = [:]
    var nextTabNumber = 1
    /// Numbers of the tabs that closed with the conversation that opened them, for the error naming why.
    var endedTabNumbers: Set<Int> = []
    /// Tabs currently flagged `isAgentControlled`, to clear the ones that left a folder.
    var controlledTabIds: Set<UUID> = []
    /// Hosts agent tabs of a space no window shows: off screen, transparent, never key, out of
    /// Mission Control, and clickless for the user.
    lazy var parkingWindow: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        // Never on screen, yet VoiceOver names it.
        window.title = "Agent Tabs".localized
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }()
    /// Console and network capture of each controlled tab.
    var captures: [UUID: AgentCapture] = [:]
    /// The inspector of each tab a devtools tool ran on.
    var inspectors: [UUID: AgentInspector] = [:]
    /// Inspectors of tabs that left the agent, still undoing their changes before closing the frontend.
    var inspectorReleases: [UUID: Task<Void, Never>] = [:]
    /// Frames of each tab `gif_creator` recorded, and the tabs still recording.
    var recordings: [UUID: [CGImage]] = [:]
    var recordingTabs: Set<UUID> = []
    /// Screenshots an agent took, by id, for `upload_image`.
    var screenshots: [(id: String, png: Data)] = []
    var nextScreenshotNumber = 1

    init(context: BrowserContext, socketURL: URL = AgentControl.defaultSocketURL) {
        self.context = context
        self.socketURL = socketURL
    }

    func inspector(for tabId: UUID, engine: WKWebViewTab) async throws -> AgentInspector {
        // The user closing the inspector they opened on the tab ends this connection too, and reopening
        // it gives the tab a new frontend.
        if let inspector = inspectors[tabId], inspector.isCurrent { return inspector }
        // A release still running would close the frontend this connection picks up.
        await inspectorReleases[tabId]?.value
        let inspector = try await AgentInspector.connect(to: engine.wkWebView)
        // The tab may have left the agent while the inspector started: nothing may reach it now.
        guard engine.isAgentControlled else {
            await inspector.release()
            throw AgentToolError("The tab left your tab group")
        }
        // Another call may have connected while this one waited: keep the first.
        if let existing = inspectors[tabId], existing.isCurrent {
            inspector.disconnect()
            return existing
        }
        inspectors[tabId] = inspector
        return inspector
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard server == nil else { return }
            let server = AgentSocketServer(path: socketURL) { [weak self] in self?.accept($0) }
            do {
                try server.start()
                self.server = server
                Task { await wipeAgentsProfile() }
            } catch {
                Self.logger.error("agent socket failed to start: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            stopAll()
            server?.stop()
            server = nil
        }
    }

    /// Handshake names as people know them: "claude-code" is Claude Code, "gemini-cli-mcp-client" Gemini CLI.
    static func displayName(_ clientName: String) -> String {
        let name = clientName.lowercased()
        // The Claude app's agent mode names itself after the MCP server it connects to.
        if name.hasPrefix("local-agent-mode-") { return "Claude" }
        if let known = [
            "claude-code": "Claude Code", "claude-ai": "Claude", "codex": "Codex", "codex-mcp-client": "Codex",
            "cursor": "Cursor", "cursor-vscode": "Cursor"
        ][name] { return known }
        // A name the agent styled itself ("Test Agent", "Goose") stays as it is.
        guard name == clientName, name.contains(where: { "-_.".contains($0) }) else { return clientName }
        let words = name.split(whereSeparator: { "-_. ".contains($0) }).filter { $0 != "mcp" && $0 != "client" }
        guard !words.isEmpty else { return clientName }
        return words.map { ["ai": "AI", "cli": "CLI", "ide": "IDE", "vscode": "VS Code"][$0] ?? $0.capitalized }.joined(separator: " ")
    }

    /// Stopped for good: no reconnection takes the sessions back.
    func stopAll() {
        for session in sessions {
            session.connection.close()
            end(session)
        }
    }

    private var activityPending = false
    /// The Agents spaces the sidebar leaves out, so the menu bar leaves them out too.
    private(set) var hiddenAgentsSpaceIds: Set<UUID> = []

    /// Tells every window which agents are connected and which are acting now, once per main-thread turn.
    /// A tab keeps its activity dot this long after the agent's last action on it, so quick clicks read
    /// as one stretch of work rather than a flicker.
    static let actingLinger: TimeInterval = 2

    func publishActivity() {
        guard !activityPending else { return }
        activityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let context else { return }
            activityPending = false
            let authorized = sessions.filter(\.isAuthorized)
            let since = Date().addingTimeInterval(-Self.actingLinger)
            // The Agents space each agent works in: one with no folder yet works in none.
            let working = Dictionary(uniqueKeysWithValues: authorized.compactMap { session in
                agentsSpaceFolder(of: session) == nil ? nil : agentsSpaceId(of: session).map { (session.id, $0) }
            })
            var actingTabIds: Set<UUID> = []
            let clients = Set(authorized.map(\.clientName)).sorted().map { name in
                let mine = authorized.filter { $0.clientName == name }
                // A tab of the call running now, however long it takes, or of one that just ended.
                let acting = mine.flatMap { session in
                    session.actedOn.filter { $0.value > since || (session.activeCalls > 0 && $0.value >= session.callStartedAt) }.keys
                }
                actingTabIds.formUnion(acting)
                return [
                    "name": name, "busy": mine.contains { $0.activeCalls > 0 }, "actingTabIds": acting.map(\.uuidString),
                    "spaceIds": Set(mine.compactMap { working[$0.id] }).map(\.uuidString)
                ] as [String: Any]
            }
            // The latest call running on a tab sets its cursor's mood; one that just ended leaves it until the dot goes out.
            // The latest one in an Agents space sets the mood of the space's mascot.
            var moods: [Int: (mood: AgentCursorView.Mood, startedAt: Date)] = [:]
            var spaceMoods: [UUID: (mood: AgentCursorView.Mood, startedAt: Date)] = [:]
            for session in authorized {
                let space = working[session.id]
                for call in session.tabCalls.values {
                    let mood: AgentCursorView.Mood = session.waitingForUser ? .waitingForUser : call.mood
                    if call.startedAt >= moods[call.tab]?.startedAt ?? .distantPast { moods[call.tab] = (mood, call.startedAt) }
                    if let space, call.startedAt >= spaceMoods[space]?.startedAt ?? .distantPast { spaceMoods[space] = (mood, call.startedAt) }
                }
            }
            for (id, capture) in captures {
                guard let webView = capture.webView else { continue }
                if let mood = tabNumbers[id].flatMap({ moods[$0]?.mood }) {
                    AgentCursorView.setMood(mood, in: webView)
                } else if !actingTabIds.contains(id) {
                    AgentCursorView.setMood(nil, in: webView)
                }
            }
            let spaceIds = context.settingsStore?.agentsSpaceIds ?? []
            // With no agent working there and no tab left, a space has nothing to show: the bar leaves it
            // out. The blank tab a space keeps after its last close does not count.
            let busy = Set(working.values)
            hiddenAgentsSpaceIds = Set(spaceIds.filter { id in
                !busy.contains(id) && context.browserState.structuralProjection(forSpace: id)?
                    .tabs.contains { !$0.isClosed && ($0.kind != .web || $0.url != nil) } != true
            })
            let profileId = context.settingsStore?.get(Self.agentsProfileKey) ?? ""
            for window in context.windows.windows {
                window.bridgeRouter?.send(event: "agentActivity", data: [
                    "clients": clients, "agentsSpaceIds": spaceIds.map(\.uuidString), "agentsProfileId": profileId,
                    "hiddenAgentsSpaceIds": hiddenAgentsSpaceIds.map(\.uuidString),
                    "isolatedSpaceIds": sessions.compactMap(\.isolatedSpaceId).map(\.uuidString),
                    "moods": Dictionary(uniqueKeysWithValues: spaceMoods.map { ($0.key.uuidString, $0.value.mood.rawValue) })
                ])
            }
        }
    }

    private static let allowedClientsKey = "agentAllowedClients"
    /// The question asked of each client, by name and identity, and how many of its connections still wait on it.
    private var pendingConsents: [String: (question: Task<Bool?, Never>, waiting: Int)] = [:]
    /// Questions shown in the drawers, by request id, with what the drawers show, until the user answers.
    private(set) var pendingConsentAnswers: [String: (answer: CheckedContinuation<Bool?, Never>, request: [String: Any])] = [:]

    /// The client names the user let drive Lilo, each with the identities (`clientIdentity`) it was allowed as.
    var allowedClients: [String: [String]] {
        context?.settingsStore?.get(Self.allowedClientsKey)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: Data($0.utf8)) } ?? [:]
    }

    private func saveAllowedClients(_ clients: [String: [String]]) {
        if let data = try? JSONEncoder().encode(clients), let json = String(bytes: data, encoding: .utf8) {
            context?.settingsStore?.set(Self.allowedClientsKey, value: json)
        }
    }

    /// Forgets one client's approval and drops its connections: it has to ask again.
    func revoke(_ name: String) {
        var clients = allowedClients
        clients[name] = nil
        saveAllowedClients(clients)
        for session in sessions where session.clientName == name {
            session.connection.close()
            end(session)
        }
    }

    /// What an approval binds to, the executable shown when asking, and its process: the agent that launched
    /// `lilo-mcp`, else the socket's peer itself. A Developer ID or App Store signed agent is known by its signing
    /// identifier and team, so its updates keep the approval; any other by its path. Empty when unknown.
    nonisolated static func clientIdentity(peer: pid_t) -> (identity: String, executable: String, pid: pid_t) {
        func code(_ pid: pid_t) -> (code: SecCode, staticCode: SecStaticCode, path: String)? {
            var code: SecCode?
            var staticCode: SecStaticCode?
            var url: CFURL?
            guard pid > 0, SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
                  let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
            return (code, staticCode, (url as URL).resolvingSymlinksInPath().path)
        }
        // lilo-mcp only relays: the agent is the process that launched it. An update replacing lilo-mcp on disk leaves
        // the running one with no code to read, its path naming the new file or nothing: it counts as a relay too, as
        // only its parent could vouch for it.
        var client = code(peer)
        var pid = peer
        let helper = URL(fileURLWithPath: AgentClientConfig.helperPath).resolvingSymlinksInPath().path
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if client?.path == helper || (client == nil && (proc_pidpath(peer, &path, UInt32(path.count)) <= 0
            || URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == helper)) {
            var info = proc_bsdinfo()
            guard proc_pidinfo(peer, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return ("", "", peer) }
            pid = pid_t(info.pbi_ppid)
            client = code(pid)
        }
        guard let client else { return ("", "", pid) }
        let executable = (client.path as NSString).abbreviatingWithTildeInPath
        var info: CFDictionary?
        SecCodeCopySigningInformation(client.staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let signing = info as? [String: Any]
        var requirement: SecRequirement?
        // The team only counts once Apple's chain vouches for it; a quote would let a name rewrite the requirement.
        if let team = signing?[kSecCodeInfoTeamIdentifier as String] as? String,
           let identifier = signing?[kSecCodeInfoIdentifier as String] as? String, !(team + identifier).contains("\""),
           SecRequirementCreateWithString(
               "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement
           ) == errSecSuccess, SecCodeCheckValidity(client.code, [], requirement) == errSecSuccess {
            return ("\(identifier) \(team)", executable, pid)
        }
        return (client.path, executable, pid)
    }

    private static let lastSeenKey = "agentClientLastSeen"

    /// When each allowed client last connected or left, in seconds since 1970.
    var lastSeen: [String: TimeInterval] {
        context?.settingsStore?.get(Self.lastSeenKey)
            .flatMap { try? JSONDecoder().decode([String: TimeInterval].self, from: Data($0.utf8)) } ?? [:]
    }

    private func markSeen(_ name: String) {
        var seen = lastSeen
        seen[name] = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(seen), let json = String(bytes: data, encoding: .utf8) {
            context?.settingsStore?.set(Self.lastSeenKey, value: json)
        }
    }

    /// Asks the user the first time a client name connects from an executable; concurrent connections of one
    /// client share the question. The name alone is no credential: any program can claim it. Without `asking`,
    /// only an approval already given counts. Nil when the user did not answer: the next try asks again.
    func authorize(_ session: AgentSession, asking: Bool = true) async -> Bool? {
        let name = session.clientName
        // Reading code signatures touches the disk: off the main thread, before any approval is looked up.
        if session.identity.isEmpty {
            let peer = session.connection.peerPID
            (session.identity, session.executable, session.clientPID) = await Task.detached { AgentControl.clientIdentity(peer: peer) }.value
        }
        if session.identity.isEmpty { Self.logger.warning("Could not read the signature of \(name, privacy: .public): asking for this connection only") }
        #if DEBUG
        // A harness that launches its own Debug build drives it without a prompt; a Release build never reads this.
        if ProcessInfo.processInfo.environment["LILO_AGENT_ALLOW_ALL"] == "1" { return true }
        #endif
        if !session.identity.isEmpty, allowedClients[name]?.contains(session.identity) == true {
            markSeen(name)
            return true
        }
        guard asking else { return nil }
        let key = name + "\n" + session.identity
        let identity = session.identity
        let question = pendingConsents[key]?.question ?? Task { @MainActor in
            Self.logger.notice("Asking the user to allow \(name, privacy: .public)")
            let allowed = await self.askConsent(name, executable: session.executable, timeout: Self.connectionConsentTimeout)
            Self.logger.notice("\(name, privacy: .public) \(allowed.map { $0 ? "allowed" : "denied" } ?? "unanswered", privacy: .public)")
            // Dropped here, as every connection waiting on it may have left: a finished question is never reused.
            self.pendingConsents[key] = nil
            // Remembered here rather than by a waiting connection: a client that reconnects in between is let in.
            if allowed == true, !identity.isEmpty, self.allowedClients[name]?.contains(identity) != true {
                var clients = self.allowedClients
                clients[name, default: []].append(identity)
                self.saveAllowedClients(clients)
                self.markSeen(name)
            }
            return allowed
        }
        pendingConsents[key] = (question, (pendingConsents[key]?.waiting ?? 0) + 1)
        // Clients such as an agent app's local mode open a connection per try and leave while the user is
        // still on the way: the question stays up for the next one. Only an unidentified client's question
        // goes with its last connection, as its approval could reach no one.
        return await withTaskCancellationHandler { await question.value } onCancel: {
            Task { @MainActor in
                guard let pending = self.pendingConsents[key], pending.question == question else { return }
                self.pendingConsents[key]?.waiting -= 1
                if pending.waiting == 1, identity.isEmpty { question.cancel() }
            }
        }
    }

    /// Asked in every window's address-bar drawer, which leaves the user's typing alone; the Dock icon
    /// bounces when Lilo is in the background. Nil when nothing could ask, or unanswered after `timeout`, or cancelled.
    func askConsent(
        _ name: String, executable: String = "", profileName: String? = nil, action: [String: String]? = nil, timeout: TimeInterval = 120
    ) async -> Bool? {
        guard let windows = context?.windows.windows, !windows.isEmpty else { return nil }
        let requestId = UUID().uuidString
        let request: [String: Any] = [
            "requestId": requestId, "clientName": Self.displayName(name), "executable": executable, "profileName": profileName ?? "",
            "action": action ?? NSNull()
        ]
        for window in windows { window.bridgeRouter?.send(event: "agentControlRequested", data: request) }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.answerConsent(requestId, granted: nil) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pendingConsentAnswers[requestId] = ($0, request) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerConsent(requestId, granted: nil) }
        }
    }

    /// Shows the questions still waiting in a window whose chrome page just loaded: one that loaded or reloaded
    /// after a question was sent never got it.
    func resendPendingConsents(to router: BridgeRouter?) {
        for pending in pendingConsentAnswers.values { router?.send(event: "agentControlRequested", data: pending.request) }
    }

    static let asksBeforeActionsKey = "agentAskBeforeActions"
    static let alwaysAllowedSitesKey = "agentAlwaysAllowedSites"

    /// Sites where the user always lets agents send, pay, delete or publish, their subdomains included.
    var alwaysAllowedSites: [String] {
        context?.settingsStore?.get(Self.alwaysAllowedSitesKey)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    /// Asks the user before a click or Enter whose target sends, pays, buys, orders, deletes, transfers, publishes
    /// or signs up, and before a request the page's cookies sign. `target` locates the control for AgentPage.js's
    /// `consequential`; `kind` is "click", "enter" or "fetch", whose `label` is the request.
    /// True when the user was asked and allowed it.
    @discardableResult
    func approveConsequentialAction(
        _ kind: String, target: [String: Any] = [:], label: String? = nil, frame: WKFrameInfo?, engine: WKWebViewTab, session: AgentSession
    ) async throws -> Bool {
        guard context?.settingsStore?.get(Self.asksBeforeActionsKey) != "false" else { return false }
        let site = engine.currentURL?.host() ?? ""
        guard !alwaysAllowedSites.contains(where: { site == $0 || site.hasSuffix("." + $0) }) else { return false }
        var found = label
        if found == nil {
            let answer = try await AgentTools.page(engine, "consequential", target, in: frame)
            found = answer as? String
            // Focus inside a frame (an embedded payment form): the frame holding the field says what Enter submits.
            if found == nil, (answer as? [String: Any])?["inFrame"] != nil {
                for (_, subframe) in await AgentTools.subframes(of: engine) {
                    found = try? await AgentTools.page(engine, "consequential", target, in: subframe) as? String
                    if found != nil { break }
                }
            }
        }
        guard let label = found else { return false }
        // Answered before the tool's own deadline, so the agent learns the user is needed.
        let action = ["kind": kind, "label": label, "site": site, "tab": engine.currentTitle ?? ""]
        session.waitingForUser = true
        publishActivity()
        let allowed = await askConsent(session.clientName, action: action, timeout: 45)
        session.waitingForUser = false
        publishActivity()
        guard allowed == true else {
            let what = ["enter": "pressing Enter to submit", "fetch": "sending"][kind] ?? "clicking"
            throw AgentToolError("The user did not allow \(what) \"\(label)\" on \(site): ask them to do it or to allow it", code: "needs_user")
        }
        return true
    }

    /// Asks the user before a page receives one of their files, whatever the setting above: an agent could
    /// otherwise hand any file it can name to any site. Returns the file, its symbolic links resolved.
    func approveUpload(_ url: URL, engine: WKWebViewTab, session: AgentSession) async throws -> URL {
        let file = url.resolvingSymlinksInPath()
        let site = engine.currentURL?.host() ?? ""
        let path = (file.path as NSString).abbreviatingWithTildeInPath
        let action = ["kind": "upload", "label": path, "site": site, "tab": engine.currentTitle ?? ""]
        session.waitingForUser = true
        publishActivity()
        let allowed = await askConsent(session.clientName, action: action, timeout: 45)
        session.waitingForUser = false
        publishActivity()
        guard allowed == true else {
            throw AgentToolError("The user did not allow uploading \(path) to \(site): ask them to upload it or to allow it", code: "needs_user")
        }
        return file
    }

    /// The user's answer from a window's drawer, nil when nobody answered: the others drop the same question.
    /// `alwaysAllowSite` is the site of an action the user always allows from now on.
    func answerConsent(_ requestId: String, granted: Bool?, alwaysAllowSite: String? = nil) {
        guard let answer = pendingConsentAnswers.removeValue(forKey: requestId)?.answer else { return }
        if granted == true, let site = alwaysAllowSite, !site.isEmpty, !alwaysAllowedSites.contains(site),
           let data = try? JSONEncoder().encode(alwaysAllowedSites + [site]), let list = String(bytes: data, encoding: .utf8) {
            context?.settingsStore?.set(Self.alwaysAllowedSitesKey, value: list)
        }
        for window in context?.windows.windows ?? [] {
            window.bridgeRouter?.send(event: "permissionRequestClosed", data: ["requestId": requestId])
        }
        answer.resume(returning: granted)
    }

    /// The session's tabs go back to normal first, then close: an engine held elsewhere keeps no agent state.
    private func end(_ closing: AgentSession) {
        guard sessions.contains(where: { $0 === closing }) else { return }
        sessions.removeAll { $0 === closing }
        refreshControlledTabs()
        for request in closing.requests.values { request.cancel() }
        if closing.isAuthorized { markSeen(closing.clientName) }
        context?.powerKeeper.terminalEnded(closing.id)
        dropFolder(of: closing)
        dropIsolatedSpace(of: closing)
        publishActivity()
        // The last agent with tabs in the agents' profile gone, nothing it did there is kept for the next one.
        if !sessions.contains(where: { $0.profileId == nil && agentsSpaceFolder(of: $0) != nil }) { Task { await wipeAgentsProfile() } }
    }

    /// lilo-mcp replays the handshake when it reconnects, and an agent may launch a new lilo-mcp: a new connection
    /// from the same agent process carries on the conversation its dropped one held, with its tabs.
    func resumeDroppedSession(into session: AgentSession) {
        guard let dropped = sessions.first(where: { $0 !== session && $0.connection.isClosed && $0.isAuthorized && Self.sameClient($0, session) })
        else { return }
        handOver(dropped, to: session)
    }

    /// The same agent: its process, or a launcher it starts lilo-mcp through afresh each time (Claude's `disclaimer`),
    /// known then by the code signing it was approved under. Signing alone needs the earlier launcher gone: two
    /// conversations of one agent app, each in its own live process, sign alike yet keep their own tabs.
    private static func sameClient(_ earlier: AgentSession, _ later: AgentSession) -> Bool {
        guard earlier.clientName == later.clientName else { return false }
        if earlier.clientPID > 0, earlier.clientPID == later.clientPID { return true }
        return !earlier.identity.isEmpty && earlier.identity == later.identity
            && !(earlier.clientPID > 0 && (kill(earlier.clientPID, 0) == 0 || errno == EPERM))
    }

    private func handOver(_ dropped: AgentSession, to session: AgentSession) {
        session.folderId = dropped.folderId
        session.isolatedSpaceId = dropped.isolatedSpaceId
        session.title = dropped.title
        session.projectName = dropped.projectName
        session.actedOn = dropped.actedOn
        session.profileId = dropped.profileId
        sessions.removeAll { $0 === dropped }
        context?.powerKeeper.terminalEnded(dropped.id)
    }

    /// The agent's new lilo-mcp may connect before its old connection is gone: that one takes the tabs.
    private func handToHeir(_ closed: AgentSession) -> Bool {
        guard let heir = sessions.first(where: {
            $0 !== closed && !$0.connection.isClosed && $0.isAuthorized && $0.folderId == nil && $0.isolatedSpaceId == nil && Self.sameClient(closed, $0)
        }) else { return false }
        handOver(closed, to: heir)
        refreshControlledTabs()
        publishActivity()
        return true
    }

    private func accept(_ connection: AgentConnection) {
        let session = AgentSession(connection: connection)
        sessions.append(session)
        connection.onClose = { [weak self, weak session] in
            guard let self, let session else { return }
            // A cancelled request gets no reply, and stops what it was doing for a client that is gone.
            for request in session.requests.values { request.cancel() }
            session.authorization?.cancel()
            let keeps = session.isAuthorized && (session.folderId != nil || session.isolatedSpaceId != nil)
            if keeps, self.handToHeir(session) { return }
            // Lilo may drop a connection the bridge then makes again: its tabs, and what the agent set on them, wait.
            guard keeps, Self.reconnectGrace > .zero else {
                return end(session)
            }
            Task { [weak self] in
                let deadline = ContinuousClock.now + Self.reconnectGrace
                while ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(500))
                    // Taken over already, or its launcher exited since and the agent's new connection takes the tabs.
                    guard let self, self.sessions.contains(where: { $0 === session }), !self.handToHeir(session) else { return }
                }
                self?.end(session)
            }
        }
        connection.onMessage = { [weak self, weak session] data in
            guard let self, let session else { return }
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let requestId = message?["method"] != nil ? message?["id"] as? AnyHashable : nil
            let request = Task { @MainActor in
                let reply = await AgentMCP.handle(message, session: session, control: self)
                if let requestId { session.requests[requestId] = nil }
                guard !Task.isCancelled else { return }
                if let reply {
                    // A screenshot's reply is megabytes of JSON: encoded off the main thread.
                    nonisolated(unsafe) let reply = reply
                    guard let line = await Task.detached(operation: { AgentConnection.line(reply) }).value else { return }
                    session.connection.send(line)
                }
            }
            if let requestId { session.requests[requestId] = request }
        }
    }
}

@MainActor
final class AgentSession {
    let connection: AgentConnection
    /// `clientInfo.name` from the MCP handshake: what the agent calls itself, never a credential.
    var clientName = "Agent"
    /// The process behind the connection, which approvals bind to: see `AgentControl.clientIdentity`. Empty until
    /// the handshake reads it.
    var identity = ""
    var executable = ""
    /// That process's id: a new connection from it carries on this conversation. 0 until the handshake reads it.
    var clientPID: pid_t = 0
    var lastActivity = Date()
    let id = UUID()
    /// Tool calls in flight, for the activity indicator.
    var activeCalls = 0
    /// A call waits on the user's answer in Lilo: its progress notifications say so.
    var waitingForUser = false
    /// The client's requests still running, by JSON-RPC id: `notifications/cancelled` or the connection
    /// closing cancels them.
    var requests: [AnyHashable: Task<Void, Never>] = [:]
    /// When this agent last acted on each tab, for the activity dot.
    var actedOn: [UUID: Date] = [:]
    var callStartedAt = Date.distantPast
    /// The calls in flight on a tab, by call: one the client gave up on keeps running in the page.
    var tabCalls: [UUID: (tab: Int, tool: String, startedAt: Date, mood: AgentCursorView.Mood)] = [:]
    /// The profile it works in, nil for the agents' own ephemeral one.
    var profileId: UUID?
    /// Its own tab folder in the Agents space of its profile, created with its first tab: one per conversation.
    var folderId: UUID?
    /// Its private space for isolated tabs, created with the first one and deleted when it leaves.
    var isolatedSpaceId: UUID?
    /// What its folder is named after: the task it gave, else its project folder, else when it came.
    var title: String?
    var projectName: String?
    let connectedAt = Date()
    /// It offered its project folders (MCP roots) at the handshake.
    var supportsRoots = false
    /// Handlers of the replies awaited from the client to Lilo's own requests, by request id.
    var pendingReplies: [String: ([String: Any]?) -> Void] = [:]
    var nextRequestId = 1
    /// Set once the user allowed this client; tools answer nothing before.
    var isAuthorized = false
    /// The question to the user, asked after the handshake replied: a client waits for its handshake less long
    /// than the user may take to answer.
    var authorization: Task<Void, Never>?
    /// The user clicked Deny: its tool calls say so. The connection stays open, as lilo-mcp would reconnect and ask again.
    var isRefused = false
    /// The question ended unanswered (no window, timed out, withdrawn): the next tool call asks again.
    var isUnanswered = false

    init(connection: AgentConnection) {
        self.connection = connection
    }
}
