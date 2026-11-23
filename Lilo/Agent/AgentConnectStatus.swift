import Foundation

/// `connect_status`: the calling agent's own setup check - which agent app Lilo took it for, whether that
/// app's configuration names this Lilo's MCP server, the exact command or snippet fixing a missing or
/// stale entry, and the consent its calls run under. Read-only is a hard line: no setter exists or ever
/// gets added to the tool surface, as a write path would let a hijacked session edit the client files or
/// the permission store that gates it. The reply is built key by hand: the sites a client may act on
/// unasked stay out, and `fix` holds only what the settings page already shows the user.
@MainActor
enum AgentConnectStatus {
    /// Every key `snapshot` produces, "group.name" for a nested one: the test resolves each in the
    /// reply and checks nothing else is there, so a key added to one but not the other fails.
    static let allowlist = [
        "client", "status", "fix",
        "consent.askBeforeActions", "consent.actsOnPages"
    ]

    static let definitions: [[String: Any]] = [
        AgentTools.tool("connect_status", """
            Check your own setup in one call: which agent app Lilo takes you for, whether that app's \
            configuration names Lilo's MCP server (connected, stale or missing; unknown when your app is \
            not one Lilo knows), the exact command or JSON that fixes it, and the consent your calls run \
            under - whether your consequential actions ask the user first and your acts-on-pages tier. \
            When status is not "connected", hand `fix` to the user: only they can apply it. \
            Nothing here can be set: ask the user to change it.
            """, [:])
    ]

    static func call(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> [AgentContent]? {
        guard name == "connect_status" else { return nil }
        return [.text(AgentTools.json(try await snapshot(for: session, control: control)))]
    }

    static func snapshot(
        for session: AgentSession, control: AgentControl,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> [String: Any] {
        guard let store = control.context?.settingsStore else { throw AgentToolError("Lilo is not ready yet") }
        let client = AgentClientConfig.Client(clientName: session.clientName)
        var status = "unknown"
        var fix: Any = AgentClientConfig.genericConfigJSON
        if let client {
            // The files are read off the main thread, as publishAgentClients does.
            let (configured, stale) = await Task.detached {
                (AgentClientConfig.connectedClients(home: home).contains(client),
                 AgentClientConfig.staleClients(home: home).contains(client))
            }.value
            status = configured ? (stale ? "stale" : "connected") : "missing"
            fix = status == "connected" ? NSNull() : AgentClientConfig.manualSnippet(client)
        }
        return [
            "client": client?.rawValue ?? "other",
            "status": status,
            "fix": fix,
            "consent": [
                "askBeforeActions": store.get(AgentControl.asksBeforeActionsKey) != "false",
                "actsOnPages": (control.clientPermissions[client?.rawValue ?? session.clientName]?.act ?? .ask).rawValue
            ]
        ]
    }
}
