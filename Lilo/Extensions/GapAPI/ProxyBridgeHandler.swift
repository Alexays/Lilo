import Foundation
import Network
import WebKit

/// chrome.proxy.settings, applied to the profile's data store through `proxyConfigurations`. Values
/// are kept in Chrome's normalized form (default schemes and ports filled in), which `get` returns.
/// Also asks `webRequest.onAuthRequired` for the credentials of a proxy that challenges a tab's load.
@MainActor
final class ProxyBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["proxy.get", "proxy.set", "proxy.clear", "webRequest.answerAuth"]

    private static let key = "proxy.settings"
    private static let incognitoKey = "proxy.settings.incognito"
    private static let defaultValue: [String: Any] = ["mode": "system"]
    static let incognitoError = "You do not have permission to access incognito preferences."

    private let settingsProvider: (ProfileExtensionRegistry) -> ExtensionSettingsStore?
    /// The effective value last applied per profile, so a load or unload that changes nothing stays quiet.
    private var applied: [UUID: NSDictionary] = [:]
    nonisolated(unsafe) private var observers: [Any] = []

    /// An extension's worker (no `pageChannel`) or one of its pages.
    private struct AuthContext: Hashable {
        let extensionId: String
        let pageChannel: Int?
    }

    /// A proxy challenge waiting on the contexts with a blocking listener; a nil answer leaves it to Lilo's prompt.
    private struct AuthRequest {
        var awaiting: Set<AuthContext>
        let completion: @MainActor (_ answer: (URLSession.AuthChallengeDisposition, URLCredential?)?) -> Void
        let registry: ProfileExtensionRegistry
        let challenger: (host: String, port: Int)
        let deadline: ContinuousClock.Instant
    }
    private var authRequests: [String: AuthRequest] = [:]
    private var nextAuthRequest = 0
    /// The request id of each tab's last proxy challenge, which a retry keeps as Chrome does.
    private let lastAuthRequestIds = NSMapTable<TabExtensionAdapter, NSString>.weakToStrongObjects()
    /// How long extensions get to answer before the challenge goes to Lilo's prompt.
    private static let authAnswerTimeout: Duration = .seconds(30)
    /// Reported by a context with a blocking or asyncBlocking listener, which answers each challenge it hears (webRequest.ts).
    private static let blockingAuthListener = "webRequest.onAuthRequired.blocking"

    init(settingsProvider: @escaping (ProfileExtensionRegistry) -> ExtensionSettingsStore?) {
        self.settingsProvider = settingsProvider
        // A setting applies only while its extension is loaded.
        observers = [Notification.Name.extensionRuntimeLoaded, .extensionDidUnload].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let registry = note.object as? ProfileExtensionRegistry else { return }
                MainActor.assumeIsolated { self?.apply(registry) }
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let settings = settingsProvider(call.registry) else { return BridgeError("Extension settings unavailable") }
        let loadedIds = call.registry.loadedExtensions.map(\.id)
        let allowsPrivate = call.context?.hasAccessToPrivateData == true
        switch call.action {
        case "proxy.get":
            let incognito = call.bool("incognito")
            if incognito && !allowsPrivate { return BridgeError(Self.incognitoError) }
            let incognitoController = incognito ? settings.controller(of: Self.incognitoKey, among: loadedIds) : nil
            let key = incognitoController == nil ? Self.key : Self.incognitoKey
            var result: [String: Any] = [
                "value": settings.controller(of: key, among: loadedIds).flatMap { settings.value(key, extensionId: $0) } ?? Self.defaultValue,
                "levelOfControl": settings.levelOfControl(of: key, for: call.extensionId, among: loadedIds)
            ]
            if incognito { result["incognitoSpecific"] = incognitoController != nil }
            return result

        case "webRequest.answerAuth":
            let context = AuthContext(extensionId: call.extensionId, pageChannel: call.int("pageChannel"))
            guard let id = call.string("requestId"), var request = authRequests[id], request.awaiting.contains(context) else { return nil }
            if call.bool("cancel") {
                finishAuth(id, (.cancelAuthenticationChallenge, nil))
            } else if let credentials = call.payload["credentials"] as? [String: Any],
                      let user = credentials["username"] as? String, let password = credentials["password"] as? String {
                applyCredential(user: user, password: password, for: request)
                finishAuth(id, (.useCredential, URLCredential(user: user, password: password, persistence: .forSession)))
            } else {
                request.awaiting.remove(context)
                authRequests[id] = request
                if request.awaiting.isEmpty { finishAuth(id, nil) }
            }
            return nil

        case "proxy.set", "proxy.clear":
            let scope = call.string("scope") ?? "regular"
            let incognito = scope == "incognito_persistent" || scope == "incognito_session_only"
            if incognito && !allowsPrivate { return BridgeError(Self.incognitoError) }
            var value: [String: Any]?
            if call.action == "proxy.set" {
                do { value = try Self.normalized(call.payload["value"]) } catch { return error }
            }
            settings.set(incognito ? Self.incognitoKey : Self.key, extensionId: call.extensionId, to: value)
            apply(call.registry)
            return nil

        default:
            return nil
        }
    }

    /// Applies the profile's effective regular value and fires `settings.onChange` when it changed.
    private func apply(_ registry: ProfileExtensionRegistry) {
        guard let settings = settingsProvider(registry) else { return }
        let loadedIds = registry.loadedExtensions.map(\.id)
        let value = settings.controller(of: Self.key, among: loadedIds).flatMap { settings.value(Self.key, extensionId: $0) as? [String: Any] }
            ?? Self.defaultValue
        let previous = applied[registry.profileId]
        guard previous?.isEqual(to: value) != true else { return }
        applied[registry.profileId] = value as NSDictionary
        // The store the profile's tabs and extension pages share.
        registry.controller.configuration.defaultWebsiteDataStore?.proxyConfigurations = Self.configurations(for: value)
        // The first value applied for a profile is its launch state, which Chrome does not announce.
        guard previous != nil else { return }
        for id in registry.extensionIds(withPermission: "proxy") {
            registry.gapEvents.emit("proxy", "settings.onChange", args: [[
                "value": value,
                "levelOfControl": settings.levelOfControl(of: Self.key, for: id, among: loadedIds)
            ]], to: [id])
        }
    }

    /// Chrome's onProxyError for a page load that failed to reach the proxy in force. WebKit reports
    /// proxy failures as connection errors, so only those count, and only while Lilo applies a proxy.
    func reportNavigationFailure(_ error: Error, registry: ProfileExtensionRegistry) {
        guard let value = applied[registry.profileId] as? [String: Any], !Self.configurations(for: value).isEmpty else { return }
        let errors = [error as NSError] + [(error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        let cfNetwork = kCFErrorDomainCFNetwork as String
        let name = errors.lazy.compactMap { error -> String? in
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorCannotFindHost),
                 (cfNetwork, Int(CFNetworkErrors.cfErrorHTTPProxyConnectionFailure.rawValue)),
                 (cfNetwork, Int(CFNetworkErrors.cfErrorHTTPSProxyConnectionFailure.rawValue)):
                return "net::ERR_PROXY_CONNECTION_FAILED"
            case (cfNetwork, Int(CFNetworkErrors.cfStreamErrorHTTPSProxyFailureUnexpectedResponseToCONNECTMethod.rawValue)):
                return "net::ERR_TUNNEL_CONNECTION_FAILED"
            default:
                return nil
            }
        }.first
        guard let name else { return }
        registry.emitGapEvent("proxy", "onProxyError", args: [["fatal": true, "error": name, "details": ""]], requiredPermission: "proxy")
    }

    // MARK: - Proxy authentication

    /// Chrome's `webRequest.onAuthRequired` for a proxy's challenge to the load of `url` in `tab`: each listening
    /// extension holding `webRequest` and `webRequestAuthProvider` may answer with credentials or cancel it.
    /// `completion` gets nil when none does, for Lilo's prompt: at once when no context has a blocking listener.
    func authenticate(
        _ challenge: URLAuthenticationChallenge, url: URL?, tab: TabExtensionAdapter?, registry: ProfileExtensionRegistry,
        completion: @escaping @MainActor (_ answer: (URLSession.AuthChallengeDisposition, URLCredential?)?) -> Void
    ) {
        let space = challenge.protectionSpace
        let candidates = registry.extensionIds(withPermission: "webRequestAuthProvider").filter { id in
            registry.heldPermissions(of: id).contains("webRequest") && url.map { registry.context(for: id)?.hasAccess(to: $0) == true } != false
        }
        let ids = registry.gapEvents.listeners(among: candidates, namespace: "webRequest", event: "onAuthRequired")
        guard !ids.isEmpty else { return completion(nil) }
        let requestId: String
        if challenge.previousFailureCount > 0, let tab, let last = lastAuthRequestIds.object(forKey: tab) as String?, authRequests[last] == nil {
            requestId = last
        } else {
            nextAuthRequest += 1
            requestId = "lilo-auth-\(nextAuthRequest)"
            if let tab { lastAuthRequestIds.setObject(requestId as NSString, forKey: tab) }
        }
        var details: [String: Any] = [
            "requestId": requestId, "url": url?.absoluteString ?? "", "method": "GET", "frameId": 0, "parentFrameId": -1,
            "type": "main_frame", "frameType": "outermost_frame", "documentLifecycle": "active",
            "timeStamp": Date().timeIntervalSince1970 * 1000, "isProxy": true,
            "scheme": space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ? "digest" : "basic",
            "challenger": ["host": space.host, "port": space.port],
            "statusCode": 407, "statusLine": "HTTP/1.1 407 Proxy Authentication Required"
        ]
        if let realm = space.realm { details["realm"] = realm }
        for id in ids {
            // The bridge turns the tab's position into the extension's tab id.
            details["tab"] = tab.flatMap { registry.tabPosition(of: $0, extensionId: id) } ?? NSNull()
            registry.gapEvents.emit("webRequest", "onAuthRequired", args: [details], to: [id])
        }
        let awaiting = Set(ids.flatMap { id in
            registry.gapEvents.contexts(of: id, listeningTo: Self.blockingAuthListener).map { AuthContext(extensionId: id, pageChannel: $0) }
        })
        guard !awaiting.isEmpty else { return completion(nil) }
        let deadline = ContinuousClock.now + Self.authAnswerTimeout
        authRequests[requestId] = AuthRequest(
            awaiting: awaiting, completion: completion, registry: registry, challenger: (space.host, space.port), deadline: deadline
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline)
            // A retry may reuse the id: only this challenge times out here.
            if self?.authRequests[requestId]?.deadline == deadline { self?.finishAuth(requestId, nil) }
        }
    }

    private func finishAuth(_ requestId: String, _ answer: (URLSession.AuthChallengeDisposition, URLCredential?)?) {
        authRequests.removeValue(forKey: requestId)?.completion(answer)
    }

    /// Credentials for the extension's own proxy go into its configuration, so its next connections need no challenge.
    private func applyCredential(user: String, password: String, for request: AuthRequest) {
        let registry = request.registry
        guard let value = applied[registry.profileId] as? [String: Any],
              let configuration = Self.configurations(for: value, at: request.challenger).first else { return }
        configuration.applyCredential(username: user, password: password)
        registry.controller.configuration.defaultWebsiteDataStore?.proxyConfigurations = [configuration]
    }

    // MARK: - Chrome's ProxyConfig

    private static let defaultPorts = ["http": 80, "https": 443, "quic": 443, "socks4": 1080, "socks5": 1080]
    private static let ruleFields = ["singleProxy", "proxyForHttp", "proxyForHttps", "proxyForFtp", "fallbackProxy"]

    /// Chrome's ProxyPrefTransformer round trip: validates the config and returns it as Chrome reads it back.
    static func normalized(_ raw: Any?) throws -> [String: Any] {
        let config = raw as? [String: Any] ?? [:]
        let mode = config["mode"] as? String ?? ""
        let pac = config["pacScript"] as? [String: Any]
        let pacURL = pac?["url"] as? String ?? ""
        let pacData = pac?["data"] as? String ?? ""
        let mandatory = pac?["mandatory"] as? Bool ?? false
        guard pacURL.allSatisfy(\.isASCII) else {
            throw BridgeError("'pacScript.url' supports only ASCII URLs (encode URLs in Punycode format).")
        }
        guard pacData.allSatisfy(\.isASCII) else {
            throw BridgeError("'pacScript.data' supports only ASCII code(encode URLs in Punycode format).")
        }

        let rules = config["rules"] as? [String: Any]
        var servers: [String: [String: Any]] = [:]
        for field in ruleFields {
            guard let server = rules?[field] as? [String: Any] else { continue }
            let host = server["host"] as? String ?? ""
            guard host.allSatisfy(\.isASCII) else {
                throw BridgeError("Invalid 'rules.???.host' entry '\(host)'. 'host' field supports only ASCII URLs (encode URLs in Punycode format).")
            }
            guard !host.isEmpty else { throw BridgeError("Invalid 'rules.???.host' entry. Hostname cannot be empty.") }
            let requested = server["scheme"] as? String ?? ""
            let scheme = defaultPorts[requested] == nil ? "http" : requested
            servers[field] = ["scheme": scheme, "host": host, "port": (server["port"] as? Int) ?? defaultPorts[scheme]!]
        }
        if servers["singleProxy"] != nil, let other = ruleFields.dropFirst().first(where: { servers[$0] != nil }) {
            throw BridgeError("Proxy rule for singleProxy and \(other) cannot be set at the same time.")
        }
        let bypassList = rules?["bypassList"] as? [String] ?? []
        guard bypassList.allSatisfy({ $0.allSatisfy(\.isASCII) }) else {
            throw BridgeError("'rules.bypassList' supports only ASCII URLs (encode URLs in Punycode format).")
        }

        switch mode {
        case "pac_script":
            guard !pacURL.isEmpty || !pacData.isEmpty else {
                throw BridgeError("Proxy mode 'pac_script' requires a 'pacScript' field with either a 'url' field or a 'data' field.")
            }
            return ["mode": mode, "pacScript": [pacURL.isEmpty ? "data" : "url": pacURL.isEmpty ? pacData : pacURL, "mandatory": mandatory]]
        case "fixed_servers":
            guard !servers.isEmpty else { throw BridgeError("Proxy mode 'fixed_servers' requires a 'rules' field.") }
            var normalizedRules: [String: Any] = servers
            // Chrome splits the joined list on both separators when it reads it back.
            let bypass = bypassList.joined(separator: ",").split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
            if !bypass.isEmpty { normalizedRules["bypassList"] = bypass }
            return ["mode": mode, "rules": normalizedRules]
        case "direct", "auto_detect", "system":
            return ["mode": mode]
        default:
            throw BridgeError("Invalid mode for proxy settings: \(mode)")
        }
    }

    /// One configuration for all traffic: WebKit cannot pick a proxy per URL scheme, run a PAC script,
    /// or speak SOCKS4 or QUIC to a proxy; those leave the system settings in charge.
    /// With `challenger`, only the configuration of that proxy host and port.
    static func configurations(for value: [String: Any], at challenger: (host: String, port: Int)? = nil) -> [ProxyConfiguration] {
        guard value["mode"] as? String == "fixed_servers", let rules = value["rules"] as? [String: Any],
              let server = ["singleProxy", "proxyForHttps", "proxyForHttp", "fallbackProxy"].lazy.compactMap({ rules[$0] as? [String: Any] }).first,
              let host = server["host"] as? String, let port = (server["port"] as? Int).flatMap({ NWEndpoint.Port(rawValue: UInt16(clamping: $0)) }),
              challenger.map({ $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == Int(port.rawValue) }) != false
        else { return [] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        var configuration: ProxyConfiguration
        switch server["scheme"] as? String {
        case "http": configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case "https": configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        case "socks5": configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        default: return []
        }
        // Chrome's bypass rules are host patterns ("*.example.com", "example.com:8080"); Network takes
        // domains, which cover their subdomains. `<local>`, `<-loopback>` and IP ranges have no equivalent.
        configuration.excludedDomains = (rules["bypassList"] as? [String] ?? []).compactMap { rule in
            var host = Substring(rule.trimmingCharacters(in: .whitespaces))
            if let separator = host.range(of: "://") { host = host[separator.upperBound...] }
            if let colon = host.lastIndex(of: ":"), !host.hasPrefix("[") { host = host[..<colon] }
            while host.hasPrefix("*") || host.hasPrefix(".") { host = host.dropFirst() }
            return host.isEmpty || host.hasPrefix("<") || host.contains("/") ? nil : String(host)
        }
        return [configuration]
    }
}
