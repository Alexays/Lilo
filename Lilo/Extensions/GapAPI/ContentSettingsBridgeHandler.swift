import Foundation

/// chrome.contentSettings: a type resolves to the winning extension's first matching rule, then Lilo's site permission
/// (camera, microphone, location, notifications), then Chrome's default. Lilo enforces those four types and javascript.
@MainActor
final class ContentSettingsBridgeHandler: GapHandler {
    private struct ContentType {
        let values: Set<String>
        let defaultValue: String
        /// Embedded rules (a secondary pattern of their own) are meaningful for it.
        var supportsSecondary = false
    }

    private static let types: [String: ContentType] = [
        "cookies": ContentType(values: ["allow", "block", "session_only"], defaultValue: "allow", supportsSecondary: true),
        "images": ContentType(values: ["allow", "block"], defaultValue: "allow", supportsSecondary: true),
        "javascript": ContentType(values: ["allow", "block"], defaultValue: "allow"),
        "location": ContentType(values: ["allow", "block", "ask"], defaultValue: "ask"),
        "popups": ContentType(values: ["allow", "block"], defaultValue: "block"),
        "notifications": ContentType(values: ["allow", "block", "ask"], defaultValue: "ask"),
        "microphone": ContentType(values: ["allow", "block", "ask"], defaultValue: "ask"),
        "camera": ContentType(values: ["allow", "block", "ask"], defaultValue: "ask"),
        "automaticDownloads": ContentType(values: ["allow", "block", "ask"], defaultValue: "ask"),
        "clipboard": ContentType(values: ["allow", "block", "ask"], defaultValue: "ask"),
        "autoVerify": ContentType(values: ["allow", "block"], defaultValue: "allow")
    ]

    let gapActions: Set<String> = ["contentSettings.get", "contentSettings.set", "contentSettings.clear"]

    private let settingsProvider: (ProfileExtensionRegistry) -> ExtensionSettingsStore?
    /// Lilo's own decision for a type it stores ("allow", "block"), nil to ask. Set by the window.
    var userSetting: ((_ type: String, _ origin: String) -> String?)?
    private var parsedPatterns: [String: ContentSettingsPattern] = [:]

    init(settingsProvider: @escaping (ProfileExtensionRegistry) -> ExtensionSettingsStore?) {
        self.settingsProvider = settingsProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let settings = settingsProvider(call.registry) else { return BridgeError("Extension settings unavailable") }
        let name = call.string("type") ?? ""
        guard let type = Self.types[name] else { return BridgeError("Invalid content setting type.") }
        let allowsPrivate = call.registry.context(for: call.extensionId)?.hasAccessToPrivateData == true
        switch call.action {
        case "contentSettings.get":
            let primaryURLString = call.string("primaryUrl") ?? ""
            guard let primaryURL = Self.validURL(primaryURLString) else { return BridgeError("The URL \"\(primaryURLString)\" is invalid.") }
            var secondaryURL = primaryURL
            if let secondary = call.string("secondaryUrl") {
                guard let url = Self.validURL(secondary) else { return BridgeError("The URL \"\(secondary)\" is invalid.") }
                secondaryURL = url
            }
            let incognito = call.bool("incognito")
            if incognito && !allowsPrivate { return BridgeError(ProxyBridgeHandler.incognitoError) }
            let setting = extensionSetting(name, primary: primaryURL, secondary: secondaryURL, settings: settings, registry: call.registry, isPrivate: incognito)
                ?? Self.origin(of: primaryURL).flatMap { origin in userSetting?(name, origin) }
                ?? type.defaultValue
            return ["setting": setting]

        case "contentSettings.set":
            let primary: ContentSettingsPattern, secondary: ContentSettingsPattern
            do {
                primary = try pattern(call.string("primaryPattern") ?? "")
                secondary = try call.string("secondaryPattern").map(pattern) ?? .wildcard
            } catch {
                return error
            }
            let setting = call.string("setting") ?? ""
            guard type.values.contains(setting) else { return BridgeError("Invalid content setting.") }
            if name == "autoVerify" && (primary != .wildcard || secondary != .wildcard) {
                return BridgeError("Site-specific settings are not allowed for this type. The URL pattern must be '<all_urls>'.")
            }
            if primary == .wildcard && secondary == .wildcard && setting == "allow" && (name == "camera" || name == "microphone") {
                return BridgeError("'allow' is not supported as the default setting of \(name).")
            }
            if primary != secondary && secondary != .wildcard && !type.supportsSecondary {
                return BridgeError("Embedded patterns are not supported for this setting.")
            }
            let incognito = call.string("scope") == "incognito_session_only"
            if incognito && !allowsPrivate { return BridgeError(ProxyBridgeHandler.incognitoError) }
            let key = Self.key(name, incognito: incognito)
            var rules = settings.value(key, extensionId: call.extensionId) as? [[String: String]] ?? []
            rules.removeAll { (try? pattern($0["primary"] ?? "")) == primary && (try? pattern($0["secondary"] ?? "")) == secondary }
            rules.append(["primary": call.string("primaryPattern") ?? "", "secondary": call.string("secondaryPattern") ?? "<all_urls>", "setting": setting])
            settings.set(key, extensionId: call.extensionId, to: rules)
            return nil

        default:
            settings.set(Self.key(name, incognito: call.string("scope") == "incognito_session_only"), extensionId: call.extensionId, to: nil)
            return nil
        }
    }

    /// The setting the profile's extensions give `type` for a page, nil when no rule matches. A
    /// private page sees its session's rules first.
    func extensionSetting(
        _ type: String,
        primary: URL,
        secondary: URL? = nil,
        settings: ExtensionSettingsStore,
        registry: ProfileExtensionRegistry,
        isPrivate: Bool
    ) -> String? {
        let loadedIds = registry.loadedExtensions.map(\.id)
        let keys = isPrivate ? [Self.key(type, incognito: true), Self.key(type, incognito: false)] : [Self.key(type, incognito: false)]
        for key in keys {
            for id in loadedIds.reversed() {
                guard let rules = settings.value(key, extensionId: id) as? [[String: String]] else { continue }
                let matching = rules.compactMap { rule -> (ContentSettingsPattern, ContentSettingsPattern, String)? in
                    guard let p = try? pattern(rule["primary"] ?? ""), let s = try? pattern(rule["secondary"] ?? ""),
                          p.matches(primary), s.matches(secondary ?? primary), let setting = rule["setting"] else { return nil }
                    return (p, s, setting)
                }
                if let best = matching.max(by: { ($0.0.precedence + $0.1.precedence).lexicographicallyPrecedes($1.0.precedence + $1.1.precedence) }) {
                    return best.2
                }
            }
        }
        return nil
    }

    private static func key(_ type: String, incognito: Bool) -> String {
        incognito ? "contentSettings.\(type).incognito" : "contentSettings.\(type)"
    }

    /// What GURL accepts for these settings: an absolute URL with a host, or a file URL.
    private static func validURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url.host?.isEmpty == false || scheme == "file" ? url : nil
    }

    /// The site permission store's key for the URL's origin.
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return PermissionOriginKey.build(scheme: scheme, host: host, port: url.port ?? 0)
    }

    private func pattern(_ string: String) throws -> ContentSettingsPattern {
        if let parsed = parsedPatterns[string] { return parsed }
        let parsed = try ContentSettingsPattern.parse(string)
        parsedPatterns[string] = parsed
        return parsed
    }
}

/// Chrome's content setting pattern, as an extension writes it: a URL match pattern over http,
/// https and file whose path matches everything (a file pattern names one path).
struct ContentSettingsPattern: Equatable {
    var scheme: String?
    /// nil matches every host.
    var host: String?
    var matchesSubdomains = false
    var port: String?
    var path: String?

    static let wildcard = ContentSettingsPattern(matchesSubdomains: true)

    static func parse(_ string: String) throws -> ContentSettingsPattern {
        if string == "<all_urls>" { return .wildcard }
        let separator = string.range(of: "://") ?? string.range(of: ":")
        guard let separator else { throw BridgeError("Missing scheme separator.") }
        let scheme = string[..<separator.lowerBound].lowercased()
        guard ["http", "https", "file", "*"].contains(scheme) else { throw BridgeError("Invalid scheme.") }
        guard string[separator] == "://" else { throw BridgeError("Wrong scheme type.") }
        let rest = string[separator.upperBound...]
        guard !rest.isEmpty else { throw BridgeError("Host can not be empty.") }

        if scheme == "file" {
            let path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/" + rest
            guard !path.contains("*"), !path.contains("?") else {
                throw BridgeError("Path wildcards in file URL patterns are not allowed.")
            }
            return ContentSettingsPattern(scheme: scheme, path: path)
        }

        guard let slash = rest.firstIndex(of: "/") else { throw BridgeError("Empty path.") }
        var host = rest[..<slash]
        guard !host.isEmpty else { throw BridgeError("Host can not be empty.") }
        var port = scheme == "*" ? "*" : scheme == "http" ? "80" : "443"
        let portSeparator = host.hasPrefix("[") ? host.range(of: "]:").map { host.index(before: $0.upperBound) } : host.firstIndex(of: ":")
        if let portSeparator {
            let value = host[host.index(after: portSeparator)...]
            guard value == "*" || (!value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber } && Int(value).map { $0 <= 65535 } == true) else {
                throw BridgeError("Invalid port.")
            }
            port = String(value)
            host = host[..<portSeparator]
        }
        var pattern = ContentSettingsPattern(scheme: scheme == "*" ? nil : scheme, port: port == "*" ? nil : port)
        if host == "*" {
            pattern.matchesSubdomains = true
        } else {
            if host.hasPrefix("*.") {
                guard host.count > 2 else { throw BridgeError("Host can not be empty.") }
                pattern.matchesSubdomains = true
                host = host.dropFirst(2)
            }
            guard !host.contains("*") else { throw BridgeError("Invalid host wildcard.") }
            pattern.host = host.lowercased()
        }
        guard rest[slash...] == "/*" else { throw BridgeError("Specific paths are not allowed.") }
        return pattern
    }

    func matches(_ url: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased() else { return false }
        if let path { return urlScheme == "file" && url.path == path }
        if let scheme { guard urlScheme == scheme else { return false } } else if self != .wildcard {
            guard urlScheme == "http" || urlScheme == "https" else { return false }
        }
        if let host {
            let urlHost = (url.host ?? "").lowercased()
            guard urlHost == host || (matchesSubdomains && urlHost.hasSuffix(".\(host)")) else { return false }
        }
        if let port {
            let urlPort = url.port.map(String.init) ?? (urlScheme == "http" ? "80" : "443")
            guard urlPort == port else { return false }
        }
        return true
    }

    /// Chrome's order between matching rules: an exact host over a domain wildcard, a longer domain
    /// over a shorter one, then a named scheme, then a named port.
    var precedence: [Int] {
        let hostRank = host.map { (matchesSubdomains ? 1 : 2, $0.split(separator: ".").count) } ?? (path == nil ? (0, 0) : (2, 0))
        return [hostRank.0, hostRank.1, scheme == nil ? 0 : 1, port == nil ? 0 : 1]
    }
}
