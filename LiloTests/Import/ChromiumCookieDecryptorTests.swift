import CommonCrypto
import CryptoKit
import XCTest
@testable import Lilo

final class ChromiumCookieDecryptorTests: XCTestCase {
    /// Encrypts like Chromium does, independently of the decryptor under test.
    static func chromiumEncrypt(_ plain: Data, password: String) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = [UInt8]("saltysalt".utf8)
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: plain.count + 16)
        var length = 0
        _ = plain.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, plain.count, &out, out.count, &length)
        }
        return Data("v10".utf8) + Data(out.prefix(length))
    }

    func testDecryptsV10Value() throws {
        let blob = Self.chromiumEncrypt(Data("session=abc".utf8), password: "peanuts")
        let value = try ChromiumCookieDecryptor(password: "peanuts").decrypt(blob, hostKey: ".example.com", stripsDomainHash: false)
        XCTAssertEqual(value, "session=abc")
    }

    func testStripsDomainHashOnNewDatabases() throws {
        let plain = Data(SHA256.hash(data: Data(".example.com".utf8))) + Data("token".utf8)
        let blob = Self.chromiumEncrypt(plain, password: "pw")
        let value = try ChromiumCookieDecryptor(password: "pw").decrypt(blob, hostKey: ".example.com", stripsDomainHash: true)
        XCTAssertEqual(value, "token")
    }

    func testWrongPasswordThrows() {
        let blob = Self.chromiumEncrypt(Data("x".utf8), password: "right")
        XCTAssertThrowsError(try ChromiumCookieDecryptor(password: "wrong").decrypt(blob, hostKey: "a", stripsDomainHash: false))
    }
}
