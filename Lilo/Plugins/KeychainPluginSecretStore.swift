import Foundation
import PluginCore
import Security

/// `PluginSecretStore` over generic-password Keychain items — the `HTTPAuthKeychain` pattern:
/// `service` scoped to this app identity, `account` naming the plugin and its setting.
final class KeychainPluginSecretStore: PluginSecretStore {
    private static let service = BuildIdentity.appIdentifier + ".plugin-secrets"

    enum StoreError: Error {
        case keychain(OSStatus)
    }

    func secret(for pluginID: String, name: String) throws -> String? {
        var query = baseQuery(account: account(pluginID, name))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch unsafe SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecItemNotFound: return nil
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case let status: throw StoreError.keychain(status)
        }
    }

    func setSecret(_ value: String, for pluginID: String, name: String) throws {
        try deleteSecret(for: pluginID, name: name)
        var item = baseQuery(account: account(pluginID, name))
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    func deleteSecret(for pluginID: String, name: String) throws {
        SecItemDelete(baseQuery(account: account(pluginID, name)) as CFDictionary)
    }

    /// `\u{1f}` appears in no manifest id or setting name.
    private func account(_ pluginID: String, _ name: String) -> String {
        "\(pluginID)\u{1f}\(name)"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }
}
