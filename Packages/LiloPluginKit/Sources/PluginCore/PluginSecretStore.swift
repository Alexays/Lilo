import Foundation

/// Where `settings:store` values of `type: "password"` live. The app's adapter is the
/// Keychain; TestingSupport's is in-memory for tests and non-macOS runs.
public protocol PluginSecretStore: Sendable {
    func secret(for pluginID: String, name: String) throws -> String?
    func setSecret(_ value: String, for pluginID: String, name: String) throws
    func deleteSecret(for pluginID: String, name: String) throws
}
