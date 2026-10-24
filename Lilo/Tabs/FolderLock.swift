import CommonCrypto
import Foundation
import LocalAuthentication
import Security

/// A folder's password protection; the password itself lives in the Keychain (`FolderLockKeychain`).
struct FolderLock: Codable, Sendable, Equatable {
    var allowsBiometrics: Bool
}

/// A folder password as a salted PBKDF2 hash in the Keychain: the password is never stored.
enum FolderLockKeychain {
    private static let service = BuildIdentity.appIdentifier + ".folder-lock"
    private static let rounds: UInt32 = 600_000
    private static let saltLength = 16
    private static let hashLength = 32

    @discardableResult
    static func setPassword(_ password: String, folderId: UUID) -> Bool {
        guard !password.isEmpty else { return false }
        var salt = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &salt) == errSecSuccess,
              let hash = derive(password, salt: salt) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(salt + hash),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Updated in place: a failed change keeps the old password rather than leaving the folder with none.
        let status = SecItemUpdate(baseQuery(folderId) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        return SecItemAdd(baseQuery(folderId).merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    static func verify(_ password: String, folderId: UUID) -> Bool {
        guard !password.isEmpty else { return false }
        var query = baseQuery(folderId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let stored = result as? Data, stored.count == saltLength + hashLength,
              let hash = derive(password, salt: Array(stored.prefix(saltLength))) else { return false }
        // Constant time: the comparison never stops at the first differing byte.
        return zip(hash, stored.suffix(hashLength)).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func remove(folderId: UUID) {
        SecItemDelete(baseQuery(folderId) as CFDictionary)
    }

    private static func derive(_ password: String, salt: [UInt8]) -> [UInt8]? {
        var hash = [UInt8](repeating: 0, count: hashLength)
        let status = password.withCString { chars in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), chars, strlen(chars), salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &hash, hashLength
            )
        }
        return status == kCCSuccess ? hash : nil
    }

    private static func baseQuery(_ folderId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: folderId.uuidString
        ]
    }
}

/// System authentication for folder locks: Touch ID, or the macOS account password.
enum FolderLockAuth {
    static var biometricsAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Read once, for the chrome to offer Touch ID; enabling and unlocking check `biometricsAvailable`.
    static let biometricsAvailableAtLaunch = biometricsAvailable

    static func authenticate(_ policy: LAPolicy, reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(policy, localizedReason: reason)) ?? false
    }
}
