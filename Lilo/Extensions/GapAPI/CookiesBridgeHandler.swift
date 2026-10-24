import Foundation

/// `cookies.getPartitionKey` for a tab's main frame: the key of a top-level document is its own site,
/// with no cross-site ancestor. Host access is checked as Chrome checks it. `cookies.changesReported`
/// answers once the changes made so far are reported.
@MainActor
final class CookiesBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["cookies.getPartitionKey", "cookies.changesReported"]

    func handle(_ call: GapCall) async -> Any? {
        if call.action == "cookies.changesReported" {
            await call.registry.cookieChangesReported()
            return nil
        }
        guard let context = call.context,
              let tab = call.registry.tabAdapters(atPositions: [call.payload["tab"] as? [String: Any] ?? [:]], extensionId: call.extensionId).first ?? nil,
              let url = tab.url(for: context) else { return BridgeError("Invalid `tabId`.") }
        guard let site = Self.site(of: url), let siteURL = URL(string: "\(site)/") else {
            return BridgeError("PartitionKey requested is not serializable.")
        }
        for checked in [siteURL, url] where !context.hasAccess(to: checked) {
            return BridgeError("No host permissions for cookies at url: \"\(checked.absoluteString)\".")
        }
        return ["partitionKey": ["topLevelSite": site, "hasCrossSiteAncestor": false]]
    }

    /// Chrome's site of `url`: its scheme and registrable domain, nil for a URL without one.
    static func site(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(registrableDomain(of: host))"
    }

    private typealias IsDomainTopLevel = @convention(c) (CFString) -> DarwinBoolean

    /// CFNetwork's public suffix lookup, the one WebKit uses; private, so it may be missing.
    private static let isDomainTopLevel: IsDomainTopLevel? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFHostIsDomainTopLevel")
        .map { unsafeBitCast($0, to: IsDomainTopLevel.self) }

    /// The host's public suffix plus one label (eTLD+1); an IP address is its own. Without the system
    /// lookup, a host falls back to its last two labels.
    static func registrableDomain(of host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2, !host.contains(":"), Int(labels[labels.count - 1]) == nil else { return host }
        if let isDomainTopLevel {
            for start in 1..<labels.count where isDomainTopLevel(labels[start...].joined(separator: ".") as CFString).boolValue {
                return labels[(start - 1)...].joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }
}
