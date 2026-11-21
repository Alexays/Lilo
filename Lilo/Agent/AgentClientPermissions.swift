import Foundation

/// What one agent may do on pages without asking, kept per client name beside the global setting and site list.
/// A client with no entry follows the global setting; `act` and `sites` only ever remove questions the user
/// answered once for all, never one about a structural hit (a sign-in or payment form, a post to another
/// origin, a frame that cannot be read): those are asked of every client.
struct AgentClientPermission: Codable, Equatable {
    enum Act: String, Codable { case ask, always }

    var act: Act = .ask
    /// Sites where this client alone acts unasked, their subdomains included.
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

    /// Whether the user is asked before an action of `client` on `site`. The global setting off and the global
    /// site list decide first, as before per-client permissions existed; then a structural hit always asks;
    /// then the client's own default and sites.
    static func asks(
        structural: Bool, site: String, globalAsks: Bool, globalSites: [String], client: AgentClientPermission?
    ) -> Bool {
        guard globalAsks, !covers(globalSites, site) else { return false }
        guard !structural, let client else { return true }
        return client.act != .always && !covers(client.sites, site)
    }

    /// Whether `site` is one of `sites` or a subdomain of one.
    static func covers(_ sites: [String], _ site: String) -> Bool {
        sites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    static func decode(_ json: String?) -> [String: AgentClientPermission] {
        json.flatMap { try? JSONDecoder().decode([String: AgentClientPermission].self, from: Data($0.utf8)) } ?? [:]
    }

    /// Entries still at the default are dropped: an absent client follows the global setting.
    static func encode(_ permissions: [String: AgentClientPermission]) -> String {
        let kept = permissions.filter { !$0.value.isDefault }
        return (try? JSONEncoder().encode(kept)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }
}
