import Foundation
import Security

/// Keychain-backed storage for HTTP Basic/Digest credentials, keyed by profile and protection space.
enum HTTPAuthKeychain {
    private static let service = BuildIdentity.appIdentifier + ".http-auth"
    /// Keychain hits, so the challenges a site keeps sending cost a lookup, not a SecItem query.
    @MainActor private static var cachedCredentialsByAccount: [String: URLCredential] = [:]

    private struct StoredCredential: Codable {
        let username: String
        let password: String
    }

    /// Stable per-profile, per-protection-space account key; `\u{1f}` appears in no UUID. Exposed for tests.
    static func storageAccount(for space: URLProtectionSpace, profileId: UUID) -> String {
        let scheme = space.protocol ?? ""
        let realm = space.realm ?? ""
        return "\(profileId.uuidString)\u{1f}\(scheme)://\(space.host):\(space.port)|\(realm)|\(space.authenticationMethod)"
    }

    @MainActor static func storedCredential(for space: URLProtectionSpace, profileId: UUID) -> URLCredential? {
        let account = storageAccount(for: space, profileId: profileId)
        if let cached = cachedCredentialsByAccount[account] { return cached }
        var query = baseQuery(account: account)
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

    @MainActor static func store(_ credential: URLCredential, for space: URLProtectionSpace, profileId: UUID) {
        guard let username = credential.user,
              let password = credential.password,
              let data = try? JSONEncoder().encode(StoredCredential(username: username, password: password)) else {
            return
        }

        delete(for: space, profileId: profileId)
        let account = storageAccount(for: space, profileId: profileId)
        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            cachedCredentialsByAccount[account] = credential
        }
    }

    @MainActor static func delete(for space: URLProtectionSpace, profileId: UUID) {
        let account = storageAccount(for: space, profileId: profileId)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        cachedCredentialsByAccount.removeValue(forKey: account)
    }

    /// Removes the profile's credentials saved since `date`, and those saved before credentials belonged to a profile,
    /// which nothing reads anymore. The keychain cannot match on a prefix, so accounts are listed first.
    @MainActor static func deleteAll(profileId: UUID, modifiedSince date: Date) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return }
        let prefix = "\(profileId.uuidString)\u{1f}"
        for item in result as? [[String: Any]] ?? [] {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) || !account.contains("\u{1f}"),
                  (item[kSecAttrModificationDate as String] as? Date ?? .distantFuture) >= date else { continue }
            SecItemDelete(baseQuery(account: account) as CFDictionary)
            cachedCredentialsByAccount.removeValue(forKey: account)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
