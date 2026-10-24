import XCTest
import Security
import CryptoKit
@testable import Lilo

final class ChromeWebStoreInstallerTests: XCTestCase {
    func testExtractsExtensionIdFromNewStoreURL() {
        let id = ChromeWebStoreInstaller.extensionId(from: URL(string:
            "https://chromewebstore.google.com/detail/ublock-origin/cjpalhdlnbpafiamejdnhcphjbkeiagm")!)
        XCTAssertEqual(id, "cjpalhdlnbpafiamejdnhcphjbkeiagm")
    }

    func testExtractsExtensionIdFromLegacyURL() {
        let id = ChromeWebStoreInstaller.extensionId(from: URL(string:
            "https://chrome.google.com/webstore/detail/name/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")!)
        XCTAssertEqual(id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    func testRejectsNonExtensionURL() {
        XCTAssertNil(ChromeWebStoreInstaller.extensionId(from: URL(string: "https://example.com/")!))
    }

    func testDownloadURLCarriesPlatformParams() throws {
        let url = try ChromeWebStoreInstaller.downloadURL(for: "cjpalhdlnbpafiamejdnhcphjbkeiagm").absoluteString
        XCTAssertTrue(url.contains("acceptformat=crx3"))
        XCTAssertTrue(url.contains("prodversion=\(ExtensionUpdateChecker.prodVersion)&"))
        XCTAssertTrue(url.contains("cjpalhdlnbpafiamejdnhcphjbkeiagm"))
    }

    /// An archive whose entry listing exceeds the 64KB pipe buffer must still extract:
    /// the listing subprocess writes more than the kernel buffers, so unzip only makes
    /// progress if the pipe is drained while it runs.
    func testUnzipHandlesListingLargerThanPipeBuffer() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let srcDir = base.appendingPathComponent("src", isDirectory: true)
        let destDir = base.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let name = String(repeating: "a", count: 120)
        for i in 0..<800 {
            try Data().write(to: srcDir.appendingPathComponent("\(name)-\(i).txt"))
        }
        let zipURL = base.appendingPathComponent("big.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", zipURL.path, "src"]
        zip.currentDirectoryURL = base
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        try await ChromeWebStoreInstaller.unzip(at: zipURL, to: destDir)
        let extracted = try fm.contentsOfDirectory(atPath: destDir.appendingPathComponent("src").path)
        XCTAssertEqual(extracted.count, 800)
    }

    func testUnzipRejectsSymlinkEntries() async throws {
        let base = try makeZipSource { src in
            try Data("x".utf8).write(to: src.appendingPathComponent("file.js"))
            try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "/etc")
        }
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try await ChromeWebStoreInstaller.unzip(at: base.appendingPathComponent("pkg.zip"), to: base.appendingPathComponent("dest"))
            XCTFail("a symlink entry must be rejected")
        } catch {}
    }

    func testUnzipStripsGroupAndOtherWriteBits() async throws {
        let base = try makeZipSource { src in
            let file = src.appendingPathComponent("file.js")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("dest")
        try await ChromeWebStoreInstaller.unzip(at: base.appendingPathComponent("pkg.zip"), to: dest)
        let permissions = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("src/file.js").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.uint16Value ?? 0) & 0o022, 0)
    }

    /// Some store packages (ClickUp, Linkclump Plus) store modes their owner cannot read: Chrome ignores them.
    func testUnzipIgnoresTheArchiveModes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("dest"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        zip.arguments = ["-I", "-c", """
            import zipfile, sys
            with zipfile.ZipFile(sys.argv[1], 'w') as z:
                for name, mode in [('assets/', 0o40300), ('assets/a.js', 0o100200), ('manifest.json', 0o100200)]:
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = mode << 16
                    z.writestr(info, '' if name.endswith('/') else '{}')
            """, base.appendingPathComponent("pkg.zip").path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let dest = base.appendingPathComponent("dest")

        try await ChromeWebStoreInstaller.unzip(at: base.appendingPathComponent("pkg.zip"), to: dest)

        let mode = { (path: String) in (try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber)?.uint16Value }
        XCTAssertEqual(try mode("assets"), 0o755)
        XCTAssertEqual(try mode("assets/a.js"), 0o644)
        XCTAssertEqual(try mode("manifest.json"), 0o644)
    }

    /// Zips the `src` folder `populate` fills (symlinks stored as links) into `<base>/pkg.zip`.
    private func makeZipSource(_ populate: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let src = base.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("dest"), withIntermediateDirectories: true)
        try populate(src)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", "-y", "pkg.zip", "src"]
        zip.currentDirectoryURL = base
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return base
    }

    // MARK: - CRX3 signature verification

    private let zipPayload = Data("PK\u{3}\u{4}minimal-fake-zip-payload".utf8)

    /// A correctly signed RSA CRX3 verifies and yields exactly the archive bytes back.
    func testValidRSACRXAccepts() throws {
        let key = try makeKey(rsa: true)
        let expectedId = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key.spki)
        let crx = try buildCRX(key: key, zip: zipPayload)

        let extracted = try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: expectedId, requirePublisherProof: false)
        XCTAssertEqual(Data(extracted), zipPayload)
    }

    /// A correctly signed ECDSA (P-256) CRX3 verifies.
    func testValidECDSACRXAccepts() throws {
        let key = try makeKey(rsa: false)
        let expectedId = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key.spki)
        let crx = try buildCRX(key: key, zip: zipPayload)

        let extracted = try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: expectedId, requirePublisherProof: false)
        XCTAssertEqual(Data(extracted), zipPayload)
    }

    /// Flipping one byte of the signature must be rejected.
    func testFlippedSignatureRejects() throws {
        let key = try makeKey(rsa: true)
        let expectedId = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key.spki)
        let crx = try buildCRX(key: key, zip: zipPayload, tamperSignature: true)

        XCTAssertThrowsError(try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: expectedId, requirePublisherProof: false))
    }

    /// Flipping one byte of the archive (signed content) must be rejected.
    func testFlippedPayloadRejects() throws {
        let key = try makeKey(rsa: true)
        let expectedId = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key.spki)
        var crx = try buildCRX(key: key, zip: zipPayload)
        crx[crx.count - 1] ^= 0xFF // last byte lives in the ZIP region

        XCTAssertThrowsError(try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: expectedId, requirePublisherProof: false))
    }

    /// A SignedData whose embedded crx_id names a different id must be rejected (proof-transplant guard).
    func testCrxIdMismatchRejects() throws {
        let key = try makeKey(rsa: true)
        let expectedId = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key.spki)
        let crx = try buildCRX(key: key, zip: zipPayload, crxIdOverride: Data(repeating: 0x00, count: 16))

        XCTAssertThrowsError(try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: expectedId, requirePublisherProof: false))
    }

    /// A header carrying signed_header_data but no proofs must be rejected.
    func testMissingProofsRejects() throws {
        let key = try makeKey(rsa: true)
        let expectedId = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key.spki)
        let crx = try buildCRX(key: key, zip: zipPayload, omitProofs: true)

        XCTAssertThrowsError(try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: expectedId, requirePublisherProof: false))
    }

    /// A valid CRX requested under the wrong extension id must be rejected.
    func testDeclaredIdMismatchRejects() throws {
        let key = try makeKey(rsa: true)
        let crx = try buildCRX(key: key, zip: zipPayload)
        let wrongId = String(repeating: "a", count: 32)

        XCTAssertThrowsError(try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: wrongId, requirePublisherProof: false))
    }

    /// A developer-signed package without the Web Store's publisher proof is not a store package.
    func testStoreInstallRequiresThePublisherProof() throws {
        let key = try makeKey(rsa: false)
        let expectedId = ExtensionArchiveSafety.chromeExtensionId(forPublicKey: key.spki)
        let crx = try buildCRX(key: key, zip: zipPayload)

        XCTAssertThrowsError(try ChromeWebStoreInstaller.extractZIP(fromCRX: crx, expectedExtensionId: expectedId, requirePublisherProof: true))
    }

    // MARK: - CRX3 fixture builders

    private struct TestKey {
        let priv: SecKey
        let spki: Data
        let rsa: Bool
    }

    private func makeKey(rsa: Bool) throws -> TestKey {
        let attributes: [CFString: Any] = rsa
            ? [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
            : [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(priv),
              let raw = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw XCTSkip("Key generation unavailable: \(String(describing: error?.takeRetainedValue()))")
        }
        // SecKey external representation is PKCS#1 (RSA) or the raw X9.63 point (EC); wrap into SPKI.
        let algorithmId: Data = rsa
            ? Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
            : Data([0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
        let bitString = der(0x03, Data([0x00]) + raw)
        let spki = der(0x30, algorithmId + bitString)
        return TestKey(priv: priv, spki: spki, rsa: rsa)
    }

    private func buildCRX(
        key: TestKey,
        zip: Data,
        tamperSignature: Bool = false,
        crxIdOverride: Data? = nil,
        omitProofs: Bool = false
    ) throws -> Data {
        let crxId = crxIdOverride ?? Data(SHA256.hash(data: key.spki).prefix(16))
        let signedData = lengthDelimited(1, crxId) // SignedData { crx_id = 1 }

        var message = Data("CRX3 SignedData\u{0}".utf8)
        message += le32(UInt32(signedData.count))
        message += signedData
        message += zip

        let algorithm: SecKeyAlgorithm = key.rsa
            ? .rsaSignatureMessagePKCS1v15SHA256
            : .ecdsaSignatureMessageX962SHA256
        var error: Unmanaged<CFError>?
        guard var signature = SecKeyCreateSignature(key.priv, algorithm, message as CFData, &error) as Data? else {
            throw XCTSkip("Signing unavailable: \(String(describing: error?.takeRetainedValue()))")
        }
        if tamperSignature { signature[signature.startIndex] ^= 0xFF }

        var header = Data()
        if !omitProofs {
            let proof = lengthDelimited(1, key.spki) + lengthDelimited(2, signature) // AsymmetricKeyProof
            header += lengthDelimited(key.rsa ? 2 : 3, proof)                        // sha256_with_(rsa|ecdsa)
        }
        header += lengthDelimited(10000, signedData)                                 // signed_header_data

        var crx = Data("Cr24".utf8)
        crx += le32(3)                       // CRX3 version
        crx += le32(UInt32(header.count))
        crx += header
        crx += zip
        return crx
    }

    // MARK: - Encoding helpers

    private func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func lengthDelimited(_ fieldNumber: Int, _ payload: Data) -> Data {
        varint(UInt64(fieldNumber << 3 | 2)) + varint(UInt64(payload.count)) + payload
    }

    private func le32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    private func der(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    private func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}
