import Foundation

/// `browser_config`: a read-only snapshot of Lilo itself that an agent legitimately needs - its
/// version, whether the content blocker is on, the default page zoom, and the agent's own permission
/// state. Read-only is a hard line: no setter exists or ever gets added to the tool surface, as a write
/// path would let a hijacked session edit the permission store that gates it. The reply comes from
/// `snapshot`, whose keys are named and mapped by hand: nothing else in the settings store reaches it,
/// and private spaces are never named. Sites where actions skip the user's approval stay out: a
/// hijacked agent would learn where it can act unasked.
@MainActor
enum AgentBrowserConfig {
    /// Every key `snapshot` produces, "group.name" for a nested one: the test resolves each in the
    /// reply and checks nothing else is there, so a key added to one but not the other fails.
    static let allowlist = [
        "lilo",
        "features.contentBlocker", "features.defaultZoom",
        "agent.profile", "agent.askBeforeActions", "agent.actionLog"
    ]

    static let definitions: [[String: Any]] = [
        AgentTools.tool("browser_config", """
            A read-only snapshot of Lilo itself: its version, whether the content blocker is on, the \
            default page zoom, and your own permission state - the profile your tabs run in \
            (list_profiles describes them all), whether the user is asked before your consequential \
            actions, and whether your calls are logged. \
            Nothing here can be set: ask the user to change it.
            """, [:])
    ]

    static func call(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> [AgentContent]? {
        guard name == "browser_config" else { return nil }
        return [.text(AgentTools.json(try snapshot(for: session, control: control)))]
    }

    private static func snapshot(for session: AgentSession, control: AgentControl) throws -> [String: Any] {
        guard let context = control.context, let store = context.settingsStore else {
            throw AgentToolError("Lilo is not ready yet")
        }
        let profile = session.profileId
            .flatMap { id in context.profileManager?.profiles.first { $0.id == id }?.name } ?? "Agents"
        return [
            "lilo": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "features": [
                "contentBlocker": store.contentBlockerEnabled,
                "defaultZoom": store.defaultZoom
            ],
            "agent": [
                "profile": profile,
                "askBeforeActions": store.get(AgentControl.asksBeforeActionsKey) != "false",
                "actionLog": store.get(AgentActionLog.settingKey) != "false"
            ]
        ]
    }
}
