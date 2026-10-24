import CryptoKit
import Foundation

/// The profile's folder of extension copies Lilo installed: store packages and temporary installs.
/// An unpacked extension loads in place from the developer's folder and is never touched. Writes hold
/// a claim for as long as their folder has no installed record, so a sweep never meets one half-done.
@MainActor
final class ExtensionFiles {
    /// Nil when installs load in place (tests without a store).
    let directory: URL?
    private var writesInFlight = 0

    init(directory: URL?) {
        self.directory = directory
    }

    /// Whether `path` is a copy Lilo installed, which it may replace or delete.
    func owns(_ path: String) -> Bool {
        directory.map { path.hasPrefix($0.path + "/") } ?? false
    }

    /// Runs an install or update: no sweep runs until it is done.
    func whileWriting<T>(_ body: () async throws -> T) async rethrows -> T {
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        return try await body()
    }

    /// Copies a temporary package into the folder (or returns `url` if already permanent), never loading from the temp copy the
    /// caller deletes. Staged then swapped so a failure keeps the previous copy; a folder `isInUse` names is never overwritten.
    func permanentCopy(of url: URL, isInUse: (String) -> Bool) throws -> URL {
        let fm = FileManager.default
        guard let directory else { return url }
        let isTempURL = url.path.hasPrefix(fm.temporaryDirectory.path) || url.path.hasPrefix(NSTemporaryDirectory())
        // A URL already inside the folder is permanent even when the folder itself sits under the temp
        // directory (tests); copying it onto itself would destroy it.
        guard isTempURL, !owns(url.path) else { return url }
        let destination = directory.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        if isInUse(destination.path) { return destination }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: url, to: staged)
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return destination
    }

    /// Swaps `extracted` in for an installed store extension: staged first, then `beforeSwap` releases the old copy and `install` takes
    /// the new one. If that throws, the previous copy returns to `rollback` and the error is rethrown; a crash leaves a backup to sweep.
    func replace(
        _ extensionId: String,
        with extracted: URL,
        beforeSwap: () async -> Void,
        install: (URL) async throws -> Void,
        rollback: (URL) async -> Void
    ) async throws {
        guard let directory else { return }
        let fm = FileManager.default
        let installed = directory.appendingPathComponent(extensionId, isDirectory: true)
        let backup = directory.appendingPathComponent(".\(extensionId).update-bak", isDirectory: true)
        let staged = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: extracted, to: staged)
        defer { try? fm.removeItem(at: staged) }
        await beforeSwap()
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: installed, to: backup)
        do {
            try fm.moveItem(at: staged, to: installed)
            try await install(installed)
        } catch {
            try? fm.removeItem(at: installed)
            try? fm.moveItem(at: backup, to: installed)
            await rollback(installed)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    /// Deletes a copy Lilo installed; a folder it does not own is left alone.
    func remove(_ path: String) {
        guard owns(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Removes folders an interrupted uninstall, install or update left (any `keeping` does not name), restoring an update backup
    /// whose live copy is missing. Matched by folder name; skipped while a write is in flight, so the next restore sweeps.
    func sweep(keeping folderNames: Set<String>) {
        guard let directory, writesInFlight == 0 else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        // Orphans are renamed away on the main actor, so an install starting later never loses files;
        // only the slow removal runs detached.
        var orphans: [URL] = []
        for name in names where !folderNames.contains(name) {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            if name.hasPrefix("."), name.hasSuffix(".update-bak") {
                let liveName = String(name.dropFirst().dropLast(".update-bak".count))
                let live = directory.appendingPathComponent(liveName, isDirectory: true)
                if folderNames.contains(liveName), !fm.fileExists(atPath: live.path), (try? fm.moveItem(at: url, to: live)) != nil { continue }
            }
            let doomed = directory.appendingPathComponent(".sweep-\(UUID().uuidString)", isDirectory: true)
            if (try? fm.moveItem(at: url, to: doomed)) != nil { orphans.append(doomed) }
        }
        guard !orphans.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in orphans { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// A store copy lives in the folder, named by its id. An unpacked extension with a manifest `key`
    /// takes the id Chrome derives from it, so native hosts' `allowed_origins` match; any other gets an
    /// id hashed from its path.
    nonisolated static func makeExtensionId(for url: URL, managedDirectory: URL?, manifestKey: String?) -> String {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let managedDirectory,
           canonical.deletingLastPathComponent().path == managedDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
           isChromeExtensionId(canonical.lastPathComponent) {
            return canonical.lastPathComponent
        }
        if let manifestKey, let publicKey = Data(base64Encoded: manifestKey, options: .ignoreUnknownCharacters), !publicKey.isEmpty {
            return ExtensionArchiveSafety.chromeExtensionId(forPublicKey: publicKey)
        }
        let digest = SHA256.hash(data: Data(canonical.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "extension-\(hex.prefix(16))"
    }

    /// 32 letters from a to p: the shape of a Chrome Web Store id.
    nonisolated static func isChromeExtensionId(_ candidate: String) -> Bool {
        guard candidate.count == 32 else { return false }
        return candidate.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 112 }
    }
}
