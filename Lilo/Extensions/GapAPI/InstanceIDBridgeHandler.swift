import Foundation
import Security

/// `chrome.instanceID`'s ID, which Chrome makes locally: random, with its creation time, kept per
/// extension until `deleteID` or an uninstall. Tokens need a push backend Lilo lacks (instanceID.ts).
@MainActor
final class InstanceIDBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["instanceID.getID", "instanceID.getCreationTime", "instanceID.deleteID"]

    private static let key = "instanceID"

    /// The calling extension's profile settings, which go with an uninstall.
    private let settingsProvider: (ProfileExtensionRegistry) -> ExtensionSettingsStore?

    init(settingsProvider: @escaping (ProfileExtensionRegistry) -> ExtensionSettingsStore?) {
        self.settingsProvider = settingsProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let settings = settingsProvider(call.registry) else { return BridgeError("Unknown error occurred.") }
        let stored = settings.value(Self.key, extensionId: call.extensionId) as? [String: Any]
        switch call.action {
        case "instanceID.getID":
            if let id = stored?["id"] as? String { return id }
            // Chrome's: 8 random bytes, the first 4 bits 0111, in base64url without padding.
            var bytes = [UInt8](repeating: 0, count: 8)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return BridgeError("Unknown error occurred.") }
            bytes[0] = 0x70 | (bytes[0] & 0x0F)
            let id = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            settings.set(Self.key, extensionId: call.extensionId, to: ["id": id, "creationTime": (Date().timeIntervalSince1970 * 1000).rounded()])
            return id
        case "instanceID.getCreationTime":
            // 0 until an ID exists, as in Chrome.
            return stored?["creationTime"] as? Double ?? 0
        default:
            settings.set(Self.key, extensionId: call.extensionId, to: nil)
            return nil
        }
    }
}
