import Foundation
import Security

/// Keychain-backed storage for HTTP Basic/Digest credentials, keyed by protection space.
enum HTTPAuthKeychain {
    private static let service = BuildIdentity.appIdentifier + ".http-auth"
    /// Keychain hits, so the challenges a site keeps sending cost a lookup, not a SecItem query.
    @MainActor private static var cachedCredentialsByAccount: [String: URLCredential] = [:]

    private struct StoredCredential: Codable {
        let username: String
        let password: String
    }

    /// Stable per-protection-space account key. Exposed for tests.
    static func storageAccount(for space: URLProtectionSpace) -> String {
        let scheme = space.protocol ?? ""
        let realm = space.realm ?? ""
        return "\(scheme)://\(space.host):\(space.port)|\(realm)|\(space.authenticationMethod)"
    }

    @MainActor static func storedCredential(for space: URLProtectionSpace) -> URLCredential? {
        let account = storageAccount(for: space)
        if let cached = cachedCredentialsByAccount[account] { return cached }
        var query = baseQuery(for: space)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(StoredCredential.self, from: data) else {
            return nil
        }

        let credential = URLCredential(user: stored.username, password: stored.password, persistence: .forSession)
        cachedCredentialsByAccount[account] = credential
        return credential
    }

    @MainActor static func store(_ credential: URLCredential, for space: URLProtectionSpace) {
        guard let username = credential.user,
              let password = credential.password,
              let data = try? JSONEncoder().encode(StoredCredential(username: username, password: password)) else {
            return
        }

        delete(for: space)
        var item = baseQuery(for: space)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            cachedCredentialsByAccount[storageAccount(for: space)] = credential
        }
    }

    @MainActor static func delete(for space: URLProtectionSpace) {
        SecItemDelete(baseQuery(for: space) as CFDictionary)
        cachedCredentialsByAccount.removeValue(forKey: storageAccount(for: space))
    }

    private static func baseQuery(for space: URLProtectionSpace) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storageAccount(for: space)
        ]
    }
}
