import Foundation

/// Which profile each conversation works in: by default the agents' own ephemeral "Agents" profile, wiped at
/// launch and once the last agent there leaves; one of the user's profiles when the agent asks and the user
/// allows it. Each profile has its own Agents space, so one agent's switch never moves another's tabs.
extension AgentControl {
    static let agentsProfileKey = "agentsProfileId"
    /// "client|identity|profileId" triples: profiles each client may switch to without asking.
    private static let profileGrantsKey = "agentProfileGrants"

    /// The agents' own profile, created the first time: no cookie, sign-in or history of the user's.
    func agentsProfileId() throws -> UUID {
        guard let context else { throw AgentToolError("Lilo is not ready yet") }
        let stored = context.settingsStore?.get(Self.agentsProfileKey).flatMap(UUID.init(uuidString:))
        if let id = context.profileManager.profiles.first(where: { $0.id == stored })?.id { return id }
        let created = try context.profileManager.createProfile(name: "Agents")
        context.settingsStore?.set(Self.agentsProfileKey, value: created.id.uuidString)
        return created.id
    }

    /// Wipes the agents' profile: what one agent's work left there never reaches the next. Only that
    /// profile, by its id, and never while a space of the user's lives in it.
    @discardableResult
    func wipeAgentsProfile() async -> Bool {
        guard let context, let id = context.settingsStore?.get(Self.agentsProfileKey).flatMap(UUID.init(uuidString:)),
              context.profileManager.profiles.contains(where: { $0.id == id }) else { return false }
        let agentsSpaces = context.settingsStore?.agentsSpaceIds ?? []
        // A private space keeps its data in memory, never in the profile.
        guard context.spaceManager.spaces(for: id).allSatisfy({ agentsSpaces.contains($0.id) || $0.isPrivate }) else { return false }
        await context.profileManager.dataStore(for: id).removeAllData(modifiedSince: .distantPast)
        if let history = try? context.profileContexts.context(for: id).history {
            try? await Task.detached { try history.clearAll() }.value
        }
        return true
    }

    /// The agents' profile is shared by every agent working in it: the others would undergo a wipe mid-task.
    /// Only an agent with open tabs there works in it: every open client connects at its launch, idle or not.
    /// Waits up to `wait` seconds for the others to close their tabs, switch profile or leave.
    private func ensureAlone(_ session: AgentSession, wait: Any?) async throws {
        let deadline = Date().addingTimeInterval(min(max((wait as? NSNumber)?.doubleValue ?? 0, 0), 600))
        while true {
            let others = sessions.filter { other in
                guard other !== session, other.profileId == nil, let folder = agentsSpaceFolder(of: other),
                      let spaceId = agentsSpaceId(of: other) else { return false }
                return !tabs(inFolder: folder.id, spaceId: spaceId).isEmpty
            }
            if others.isEmpty { return }
            guard Date() < deadline, !session.connection.isClosed else {
                let holders = others.map { "\"\(agentsSpaceFolder(of: $0)?.name ?? "")\" (last active \(Int(-$0.lastActivity.timeIntervalSinceNow)) s ago)" }
                throw AgentToolError("""
                    Another agent is working in the Agents profile: \(holders.joined(separator: ", ")). It holds it until it closes \
                    its tabs or disconnects: pass wait (seconds) to wait for that
                    """)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// An agent starting over: wipes the agents' profile and reloads its tabs, signed in nowhere.
    func resetProfile(for session: AgentSession, wait: Any?) async throws -> String {
        if let profileId = session.profileId {
            let name = context?.profileManager.profiles.first { $0.id == profileId }?.name ?? ""
            throw AgentToolError("You are in the user's profile \(name), which is never reset: switch_profile to Agents first")
        }
        try await ensureAlone(session, wait: wait)
        let (space, _) = try agentSpace(for: session)
        guard await wipeAgentsProfile() else {
            throw AgentToolError("The Agents profile holds a space of the user's, so it is not reset")
        }
        if let folderId = session.folderId {
            for tab in tabs(inFolder: folderId, spaceId: space.id) {
                (context?.windows.window(forTab: tab.id)?.tabManager.engineTab(for: tab.id)
                    ?? context?.browserState.engine(tabId: tab.id, spaceId: space.id))?.reload()
            }
        }
        return "The Agents profile is reset: no cookie, storage, cache or history left, and your tabs reloaded."
    }

    /// `space`'s profile is going away: the agents working in it go back to their own ephemeral profile, their
    /// folders to its Agents space, and `space` goes.
    func returnAgents(from space: Space) throws {
        let home = try agentSpace(in: agentsProfileId()).space
        for session in sessions where session.profileId == space.profileId {
            session.profileId = nil
            try moveFolder(of: session, from: space, to: home)
        }
        try context?.spaceManager?.deleteSpace(id: space.id)
        refreshControlledTabs()
        publishActivity()
    }

    /// Profiles for `list_profiles`: which one the session works in, which one the user works in now,
    /// and which one is the agents' ephemeral one.
    func profileList(for session: AgentSession) throws -> [[String: Any]] {
        guard let context, let spaces = context.spaceManager else { throw AgentToolError("Lilo is not ready yet") }
        let current = try session.profileId ?? agentsProfileId()
        // A private space's browsing is not the agents' business, not even which profile it is based on.
        let user = context.windows.activeWindow?.tabManager.currentSpaceId.flatMap(spaces.space(with:)).flatMap { $0.isPrivate ? nil : $0.profileId }
        let agents = try agentsProfileId()
        return context.profileManager.profiles.map {
            ["id": $0.id.uuidString, "name": $0.name, "current": $0.id == current, "usedByUser": $0.id == user, "ephemeral": $0.id == agents]
        }
    }

    /// An agent asking for another profile: the user allows each of their profiles once per client, in
    /// the address-bar drawer, as for the first connection. Back to the agents' own one needs no asking.
    /// Only this conversation's folder moves, to the Agents space of that profile.
    func switchProfile(_ query: String, for session: AgentSession) async throws -> String {
        guard let context else { throw AgentToolError("Lilo is not ready yet") }
        guard let profile = context.profileManager.profiles.first(where: {
            $0.id.uuidString == query || $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw AgentToolError("No profile \"\(query)\": list_profiles gives their names") }
        let agents = try agentsProfileId()
        let current = session.profileId ?? agents
        guard current != profile.id else { return "Already in the profile \(profile.name)" }
        if profile.id != agents, !grantedProfiles.contains(Self.grantKey(session, profile.id)) {
            guard await askConsent(session.clientName, profileName: profile.name) == true else {
                throw AgentToolError("The user did not allow the profile \(profile.name)", code: "needs_user")
            }
            grantProfile(profile.id, to: session)
        }
        // Read again: another call of the session may have switched while the user was asked.
        let source = agentsSpace(in: session.profileId ?? agents)
        let target = try agentSpace(in: profile.id).space
        if let source { try moveFolder(of: session, from: source, to: target) }
        session.profileId = profile.id == agents ? nil : profile.id
        refreshControlledTabs()
        publishActivity()
        return "Now in the profile \(profile.name): your tabs moved to it and reload with its sign-ins."
    }

    private var grantedProfiles: Set<String> {
        Set(context?.settingsStore?.get(Self.profileGrantsKey).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
    }

    private func grantProfile(_ profileId: UUID, to session: AgentSession) {
        saveProfileGrants(grantedProfiles.union([Self.grantKey(session, profileId)]))
    }

    func forgetProfileGrants(of clientName: String) {
        saveProfileGrants(grantedProfiles.filter { !$0.hasPrefix(clientName + "|") })
    }

    private func saveProfileGrants(_ grants: Set<String>) {
        if let data = try? JSONEncoder().encode(grants.sorted()), let stored = String(bytes: data, encoding: .utf8) {
            context?.settingsStore?.set(Self.profileGrantsKey, value: stored)
        }
    }

    private static func grantKey(_ session: AgentSession, _ profileId: UUID) -> String {
        "\(session.clientName)|\(session.identity)|\(profileId.uuidString)"
    }
}
