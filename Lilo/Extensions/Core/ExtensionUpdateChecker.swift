import Foundation

/// Pure helpers for the Chrome extension auto-update check (Google's Omaha "update2" protocol). Builds
/// the update-check request, parses the XML response for the latest versions, and compares versions.
/// The download + install reuses `ChromeWebStoreInstaller`; this only decides *whether* to update.
enum ExtensionUpdateChecker {
    private static let endpoint = "https://clients2.google.com/service/update2/crx"

    /// The Chrome version Lilo claims everywhere, read from the masquerade UA so the store, the CRX
    /// download and the update check never disagree.
    static let prodVersion: String = {
        let ua = ChromeMasquerade.chromeUserAgent
        guard let start = ua.range(of: "Chrome/") else { return "155.0.0.0" }
        return String(ua[start.upperBound...].prefix { $0.isNumber || $0 == "." })
    }()

    /// Web Store extensions update through Google's service. Treat a missing `update_url` as the default
    /// (Google), and a Google URL as eligible; anything else (self-hosted) is left alone.
    static func usesGoogleUpdateService(_ updateURL: String?) -> Bool {
        guard let updateURL, !updateURL.isEmpty else { return true }
        return updateURL.contains("clients2.google.com") || updateURL.contains("google.com/service/update2")
    }

    /// One Omaha update-check URL for several extensions (one `x` per id). Passing each current `v`
    /// lets the server answer `noupdate` cheaply.
    static func updateCheckURL(extensions: [(id: String, version: String)]) -> URL? {
        guard !extensions.isEmpty else { return nil }
        var query = "response=updatecheck&prodversion=\(prodVersion)&acceptformat=crx3"
        for (id, version) in extensions {
            guard let encodedX = "id=\(id)&v=\(version)&uc".addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            query += "&x=\(encodedX)"
        }
        return URL(string: "\(endpoint)?\(query)")
    }

    /// The latest version per extension id from an Omaha response. Apps answering `noupdate`, an error,
    /// or an unparseable `<updatecheck>` are left out.
    static func latestVersions(from xml: Data) -> [String: String] {
        guard let text = String(data: xml, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for app in text.components(separatedBy: "<app").dropFirst() {
            let tag = Substring(app)
            guard let id = attribute("appid", in: tag),
                  let check = tag.range(of: "<updatecheck"),
                  attribute("status", in: tag[check.lowerBound...]) == "ok",
                  let version = attribute("version", in: tag[check.lowerBound...]) else { continue }
            result[id] = version
        }
        return result
    }

    /// Reads ` name="value"` from `s` (searching forward from its start). The leading space keeps
    /// `version` from matching inside `prodversionmin`.
    private static func attribute(_ name: String, in s: Substring) -> String? {
        guard let open = s.range(of: " \(name)=\"") else { return nil }
        let rest = s[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<close])
    }

    /// Numeric, component-wise dotted-version comparison (so 1.10 > 1.9). Missing components count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<Swift.max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
