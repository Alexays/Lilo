import Foundation
import CryptoKit
import os

/// Downloads, signature-validates and extracts a CRX3 package from the Chrome Web Store into a
/// temp directory ready for `ProfileExtensionRegistry.load(from:)`. Pure of UI: callers own the
/// consent prompt. Shared by the URL-bar/ExtensionManager install path and the store handler.
enum ChromeWebStoreInstaller {
    private static let logger = Logger(liloCategory: "cws-installer")

    /// 32-char `[a-p]` extension id from a store detail URL, or nil.
    static func extensionId(from url: URL) -> String? {
        let s = url.absoluteString
        let pattern = #"/detail(?:/[^/]+)?/([a-p]{32})(?:[/?#]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).lowercased()
    }

    static func downloadURL(for extensionId: String) throws -> URL {
        // Google requires platform parameters (os, arch, prod, prodchannel) to return
        // a 302 redirect to the CRX file. Without them the server returns HTTP 204.
        let query = "response=redirect"
            + "&os=mac&arch=x86-64&nacl_arch=x86-64"
            + "&prod=chromecrx&prodchannel=stable&prodversion=\(ExtensionUpdateChecker.prodVersion)"
            + "&acceptformat=crx3"
            + "&x=id%3D\(extensionId)%26installsource%3Dondemand%26uc"
        guard let url = URL(string: "https://clients2.google.com/service/update2/crx?\(query)") else {
            throw ExtensionError.downloadFailed("could not construct CRX download URL for \(extensionId)")
        }
        return url
    }

    /// Caps a CRX download and its unpacked contents, so a hostile package cannot fill the disk.
    static let maxDownloadBytes = 256 * 1024 * 1024
    static let maxExtractedBytes: UInt64 = 1024 * 1024 * 1024

    /// Downloads + validates + unzips into `<tmp>/<uuid>/<extensionId>`: the folder name is the id the
    /// install keeps. The caller deletes the returned directory's parent.
    static func downloadAndExtract(extensionId: String) async throws -> URL {
        let downloadURL = try downloadURL(for: extensionId)
        logger.info("Downloading CRX from: \(downloadURL.absoluteString, privacy: .public)")

        var request = URLRequest(url: downloadURL)
        request.setValue(ChromeMasquerade.chromeUserAgent, forHTTPHeaderField: "User-Agent")

        let (tempFile, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw ExtensionError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }
        let size = (try? tempFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxDownloadBytes else { throw ExtensionError.downloadFailed("package larger than \(maxDownloadBytes) bytes") }

        let crxData = try Data(contentsOf: tempFile)
        let zipData = try extractZIP(fromCRX: crxData, expectedExtensionId: extensionId, requirePublisherProof: true)

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extractDir = workDir.appendingPathComponent(extensionId, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            let zipURL = workDir.appendingPathComponent("package.zip")
            try zipData.write(to: zipURL)
            defer { try? FileManager.default.removeItem(at: zipURL) }
            try await unzip(at: zipURL, to: extractDir)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }
        return extractDir
    }

    /// `requirePublisherProof` demands the Web Store's own signature, which only Google's servers can
    /// produce: a package signed by its developer alone was never reviewed by the store.
    static func extractZIP(fromCRX data: Data, expectedExtensionId: String, requirePublisherProof: Bool) throws -> Data {
        let crxMagic: [UInt8] = [0x43, 0x72, 0x32, 0x34] // "Cr24"

        guard data.count >= 12 else {
            throw ExtensionError.invalidExtensionArchive("File too small")
        }
        // Web Store downloads are always CRX3. A bare ZIP carries no signature to verify, so accepting
        // one would let anyone who can influence the download strip the header and bypass the check.
        guard [UInt8](data[0..<4]) == crxMagic else {
            throw ExtensionError.invalidExtensionArchive("Not a signed CRX3 package")
        }
        // CRX layout: magic(4) + version(4 LE) + headerLength(4 LE) + protobuf(headerLength) + zip
        let headerLen = UInt32(data[8]) | (UInt32(data[9]) << 8) | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        let zipOffset = 12 + Int(headerLen)
        guard zipOffset < data.count else {
            throw ExtensionError.invalidExtensionArchive("CRX header length exceeds file size")
        }
        let header = Data(data[12..<zipOffset])
        let archive = Data(data[zipOffset...])
        // Real CRX3 verification: at least one proof must cryptographically sign the archive, its key
        // must derive the requested id, and the embedded crx_id must match too. This proves the archive
        // content was signed by the publisher, not merely that a matching public key is present.
        guard ExtensionArchiveSafety.verifyCRX3(header: header, archive: archive, expectedExtensionId: expectedExtensionId, requirePublisherProof: requirePublisherProof) else {
            throw ExtensionError.invalidExtensionArchive("CRX3 signature verification failed")
        }
        return archive
    }

    static func unzip(at zipURL: URL, to destURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let entries = try zipEntries(at: zipURL)
                    guard entries.allSatisfy(ExtensionArchiveSafety.isSafeZipEntry) else {
                        throw ExtensionError.invalidExtensionArchive("Archive contains unsafe paths")
                    }
                    // A symlink entry could point outside the extension, and a later entry could write through it.
                    let listing = try runUnzip(["-Z", zipURL.path])
                    guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
                        throw ExtensionError.invalidExtensionArchive("Archive contains symbolic links")
                    }
                    if let totals = listing.split(separator: "\n").last?.split(separator: ","),
                       totals.count > 1,
                       let bytes = UInt64(totals[1].split(separator: " ").first ?? ""),
                       bytes > maxExtractedBytes {
                        throw ExtensionError.invalidExtensionArchive("Archive expands past \(maxExtractedBytes) bytes")
                    }
                    _ = try runUnzip(["-q", zipURL.path, "-d", destURL.path])
                    try sanitizeExtractedTree(at: destURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Rejects any symlink that slipped through and gives every item 0755 (folders) or 0644, ignoring the
    /// archive's modes as Chrome does: some store packages carry unreadable ones, which stopped the install.
    /// A folder is fixed when the walk reaches it, before the walk reads it.
    private static func sanitizeExtractedTree(at root: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                throw ExtensionError.invalidExtensionArchive("Archive contains symbolic links")
            }
            let mode: UInt16 = values.isDirectory == true ? 0o755 : 0o644
            if (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value != mode {
                try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            }
        }
    }

    /// Runs `/usr/bin/unzip` and returns its stdout. Drains the pipe before waiting: output larger than
    /// the pipe buffer blocks unzip on write, and waiting first would deadlock both processes forever.
    private static func runUnzip(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtensionError.invalidExtensionArchive("unzip failed with status \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func zipEntries(at zipURL: URL) throws -> [String] {
        try runUnzip(["-Z", "-1", zipURL.path]).split(separator: "\n").map(String.init)
    }
}
