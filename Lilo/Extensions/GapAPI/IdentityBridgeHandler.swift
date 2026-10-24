import Foundation
import Security
import os
import AppKit
import WebKit

private enum IdentityError: LocalizedError {
    case missingScopes
    case missingURL
    case missingToken
    case missingClientId
    case notGranted
    case authorizationFailed(String)
    case interactiveRequired
    case keychainError(String)
    case invalidKeychainData
    case invalidTokenEncoding
    case authFlowCanceled

    var errorDescription: String? {
        switch self {
        case .missingScopes:         return "Missing required 'scopes' parameter"
        case .missingURL:            return "Missing required 'url' parameter"
        case .missingToken:          return "Missing required 'token' parameter"
        case .missingClientId:       return "Invalid OAuth2 Client ID."
        // As a Chrome with no signed-in account: Lilo has none, so a token comes only from interactive sign-in.
        case .notGranted:            return "The user is not signed in."
        case .authorizationFailed(let m): return "Authorization failed: \(m)"
        case .interactiveRequired:   return "Interactive mode is required for this operation"
        case .keychainError(let m):  return "Keychain error: \(m)"
        case .invalidKeychainData:   return "Invalid data retrieved from Keychain"
        case .invalidTokenEncoding:  return "Token data could not be decoded as UTF-8"
        case .authFlowCanceled:      return "Authentication flow was canceled"
        }
    }
}

// MARK: - AuthFlowPanel

@MainActor
private final class AuthFlowPanel: NSObject {
    private let completion: (Result<String, Error>) -> Void
    private var window: NSPanel?
    private var webView: WKWebView?
    private var didComplete = false
    private var navDelegate: AuthNavDelegate?

    init(extensionId: String, dataStore: WKWebsiteDataStore, completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        WKFeatureFlags.apply([:], to: configuration.preferences)
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 640), configuration: configuration)
        let delegate = AuthNavDelegate(extensionId: extensionId) { [weak self] in self?.finish($0) }
        wv.navigationDelegate = delegate
        navDelegate = delegate
        webView = wv
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Sign In".localized; panel.contentView = wv
        panel.isReleasedWhenClosed = false; panel.delegate = self
        window = panel
    }

    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }
    func show() { window?.center(); window?.makeKeyAndOrderFront(nil) }
    func cancel() { finish(.failure(IdentityError.authFlowCanceled)) }

    private func finish(_ result: Result<String, Error>) {
        guard !didComplete else { return }
        didComplete = true; window?.close(); webView?.navigationDelegate = nil; navDelegate = nil; completion(result)
    }
}

extension AuthFlowPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(.failure(IdentityError.authFlowCanceled))
    }
}

// MARK: - AuthNavDelegate

private final class AuthNavDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    private let completion: (Result<String, Error>) -> Void
    private let redirectHost: String
    private var didComplete = false

    init(extensionId: String, completion: @escaping (Result<String, Error>) -> Void) {
        redirectHost = "\(extensionId.lowercased()).chromiumapp.org"
        self.completion = completion; super.init()
    }

    /// Chrome's `identity.getRedirectURL()` is `<own-id>.chromiumapp.org`; loopback is also common
    /// for local OAuth. Any other host, including a sibling extension's, never captures the code.
    private func isRedirectHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == redirectHost || host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, isRedirectHost(url.host), !didComplete {
            didComplete = true; completion(.success(url.absoluteString)); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !didComplete else { return }
        didComplete = true; completion(.failure(error))
    }
}

// MARK: - IdentityBridgeHandler

@MainActor
final class IdentityBridgeHandler: GapHandler {
    private static let logger = Logger(liloCategory: "identity-api")
    private static let keychainService = BuildIdentity.appIdentifier + ".identity"
    /// One flow per extension, so one extension cannot cancel another's sign-in.
    private var authFlowPanels: [String: AuthFlowPanel] = [:]

    let gapActions: Set<String> = [
        "identity.launchWebAuthFlow",
        "identity.getAuthToken",
        "identity.removeCachedAuthToken",
        "identity.clearAllCachedAuthTokens"
    ]

    func handle(_ call: GapCall) async -> Any? {
        do {
            switch call.action {
            // The sign-in page runs in the calling extension's profile store, so its session stays there.
            case "identity.launchWebAuthFlow":
                return try await launchWebAuthFlow(details: call.payload, extensionId: call.extensionId, dataStore: WKWebsiteDataStore(forIdentifier: call.registry.profileId))
            case "identity.getAuthToken":
                return try await getAuthToken(call, dataStore: WKWebsiteDataStore(forIdentifier: call.registry.profileId))
            case "identity.removeCachedAuthToken":
                guard let token = call.string("token"), !token.isEmpty else { throw IdentityError.missingToken }
                try removeTokens(of: call, matching: token)
                return nil
            case "identity.clearAllCachedAuthTokens":
                try removeTokens(of: call, matching: nil)
                return nil
            default:
                return nil
            }
        } catch {
            return BridgeError(error.localizedDescription)
        }
    }

    /// Chrome's getAuthToken over the manifest's `oauth2` client: a cached token while it is valid, else
    /// with `interactive` Google's OAuth consent in the sign-in panel. Chrome signs in with the browser's
    /// Google account; Lilo has none, so the user signs in there.
    private func getAuthToken(_ call: GapCall, dataStore: WKWebsiteDataStore) async throws -> [String: Any] {
        let oauth2 = call.context?.webExtension.manifest["oauth2"] as? [String: Any]
        let scopes = (call.payload["scopes"] as? [String]) ?? (oauth2?["scopes"] as? [String]) ?? []
        guard !scopes.isEmpty else { throw IdentityError.missingScopes }
        let account = Self.accountPrefix(of: call) + scopes.joined(separator: " ")
        if let token = try cachedToken(account: account) { return ["token": token, "grantedScopes": scopes] }
        guard call.bool("interactive") else { throw IdentityError.notGranted }
        guard let clientId = oauth2?["client_id"] as? String, !clientId.isEmpty else { throw IdentityError.missingClientId }

        var authorize = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorize.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "redirect_uri", value: "https://\(call.extensionId.lowercased()).chromiumapp.org/"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
        ]
        let redirect = try await runAuthFlow(authorize.url!, extensionId: call.extensionId, dataStore: dataStore)
        // The implicit grant answers in the fragment.
        var answer = URLComponents()
        answer.percentEncodedQuery = URLComponents(string: redirect)?.percentEncodedFragment
        let fields = Dictionary((answer.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        guard let token = fields["access_token"], !token.isEmpty else { throw IdentityError.authorizationFailed(fields["error"] ?? "no token") }
        let lifetime = TimeInterval(fields["expires_in"] ?? "") ?? 3600
        try storeToken(token, account: account, expiresAt: Date().addingTimeInterval(lifetime))
        return ["token": token, "grantedScopes": fields["scope"]?.split(separator: " ").map(String.init) ?? scopes]
    }

    private func launchWebAuthFlow(details: [String: Any], extensionId: String, dataStore: WKWebsiteDataStore) async throws -> String {
        guard let urlString = details["url"] as? String, let url = URL(string: urlString) else {
            throw IdentityError.missingURL
        }
        guard details["interactive"] as? Bool == true else {
            throw IdentityError.interactiveRequired
        }
        return try await runAuthFlow(url, extensionId: extensionId, dataStore: dataStore)
    }

    /// Shows `url` in the extension's sign-in panel and returns the redirect it ends on.
    private func runAuthFlow(_ url: URL, extensionId: String, dataStore: WKWebsiteDataStore) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // One flow per extension: its previous panel resumes that caller with a cancel first.
                authFlowPanels[extensionId]?.cancel()
                let panel = AuthFlowPanel(extensionId: extensionId, dataStore: dataStore) { [weak self] redirectResult in
                    self?.authFlowPanels[extensionId] = nil
                    continuation.resume(with: redirectResult)
                }
                authFlowPanels[extensionId] = panel
                panel.load(url)
                panel.show()
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.authFlowPanels.removeValue(forKey: extensionId)?.cancel() }
        }
    }

    private func keychainError(_ status: OSStatus, context: String) -> IdentityError {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        Self.logger.error("\(context): \(msg)")
        return .keychainError(msg)
    }

    /// The token cached under `account`, nil once it expires within the minute.
    private func cachedToken(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecReturnAttributes as String: true]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw keychainError(status, context: "Failed to retrieve token")
        }
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else { throw IdentityError.invalidKeychainData }
        let expiresAt = (item[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }.flatMap(TimeInterval.init)
        guard let expiresAt, Date(timeIntervalSince1970: expiresAt) > Date().addingTimeInterval(60) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func storeToken(_ token: String, account: String, expiresAt: Date) throws {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account]
        SecItemDelete(item as CFDictionary)
        var attributes = item
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrGeneric as String] = Data(String(expiresAt.timeIntervalSince1970).utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status, context: "Failed to store token") }
    }

    /// Keyed by profile and extension, so neither another extension nor the same one in another profile
    /// reads the token; `\u{1f}` appears in no id or scope.
    private static func accountPrefix(of call: GapCall) -> String {
        "\(call.registry.profileId.uuidString)\u{1f}\(call.extensionId)\u{1f}"
    }

    /// Removes the extension's cached tokens, or only those equal to `token`. The keychain never
    /// matches on a secret and returns secrets one item at a time, so accounts are listed first.
    private func removeTokens(of call: GapCall, matching token: String?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return }
            throw keychainError(status, context: "Failed to list tokens")
        }
        let accounts = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        let prefix = Self.accountPrefix(of: call)
        for account in accounts where account.hasPrefix(prefix) {
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account]
            if let token {
                var data: AnyObject?
                var read = item
                read[kSecReturnData as String] = true
                guard SecItemCopyMatching(read as CFDictionary, &data) == errSecSuccess, data as? Data == Data(token.utf8) else { continue }
            }
            SecItemDelete(item as CFDictionary)
        }
    }
}
