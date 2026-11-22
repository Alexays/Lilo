import Foundation

/// How one agent acts on pages, kept per app (its `AgentClientConfig.Client` id, or the agent's own name when no
/// app is known) beside the global setting and site list. It only ever removes questions about ordinary actions:
/// a sensitive one (signing in, paying, buying, deleting, publishing, sending data to another site) asks every agent.
struct AgentClientPermission: Codable, Equatable {
    enum Act: String, Codable { case ask, sites, always }

    var act: Act = .ask
    /// Where `.sites` acts unasked, their subdomains included.
    var sites: [String] = []

    init(act: Act = .ask, sites: [String] = []) {
        self.act = act
        self.sites = sites
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        act = (try? values.decodeIfPresent(Act.self, forKey: .act)) ?? .ask
        sites = (try? values.decodeIfPresent([String].self, forKey: .sites)) ?? []
    }

    var isDefault: Bool { act == .ask && sites.isEmpty }

    static let settingKey = "agentClientPermissions"

    /// Whether the user is asked before an action on `site`. The global setting and site list decide first; then a
    /// sensitive action always asks; then the agent's own choice.
    static func asks(sensitive: Bool, site: String, globalAsks: Bool, globalSites: [String], client: AgentClientPermission?) -> Bool {
        guard globalAsks, !covers(globalSites, site) else { return false }
        guard !sensitive, let client else { return true }
        switch client.act {
        case .ask: return true
        case .sites: return !covers(client.sites, site)
        case .always: return false
        }
    }

    /// Whether `site` is one of `sites` or a subdomain of one.
    static func covers(_ sites: [String], _ site: String) -> Bool {
        sites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    static func decode(_ json: String?) -> [String: AgentClientPermission] {
        json.flatMap { try? JSONDecoder().decode([String: AgentClientPermission].self, from: Data($0.utf8)) } ?? [:]
    }

    /// Entries still at the default are dropped: an absent agent follows the global setting.
    static func encode(_ permissions: [String: AgentClientPermission]) -> String {
        let kept = permissions.filter { !$0.value.isDefault }
        return (try? JSONEncoder().encode(kept)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }
}
