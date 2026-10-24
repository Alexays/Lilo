import CommonCrypto
import CryptoKit
import Foundation
import Security

/// macOS Chromium cookies: "v10" + AES-128-CBC, key = PBKDF2-SHA1(Keychain password, "saltysalt",
/// 1003 rounds, 16 bytes), IV = 16 spaces. Databases at meta version 24+ prefix the plaintext with
/// SHA-256(host_key).
struct ChromiumCookieDecryptor {
    private let key: Data

    init(password: String) {
        var key = Data(count: kCCKeySizeAES128)
        let salt = [UInt8]("saltysalt".utf8)
        let passwordBytes = Array(password.utf8)
        key.withUnsafeMutableBytes { keyBuffer in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, passwordBytes.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                keyBuffer.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
        }
        self.key = key
    }

    func decrypt(_ blob: Data, hostKey: String, stripsDomainHash: Bool) throws -> String {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { throw ImportError.decryption }
        let cipher = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                input.baseAddress, cipher.count, out.baseAddress, out.count, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ImportError.decryption }
        var plain = output.prefix(length)
        if stripsDomainHash, plain.count >= 32, plain.prefix(32) == Data(SHA256.hash(data: Data(hostKey.utf8))) {
            plain = plain.dropFirst(32)
        }
        guard let value = String(data: plain, encoding: .utf8) else { throw ImportError.decryption }
        return value
    }

    /// Triggers macOS's "Lilo wants to use 'Chrome Safe Storage'" prompt.
    static func keychainPassword(service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw ImportError.keychain(status)
        }
        return password
    }
}
