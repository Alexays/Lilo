import CryptoKit
import Foundation

/// The profile's folder of extension copies Lilo installed: store packages and temporary installs.
/// An unpacked extension loads from Lilo's clone of the developer's folder, which is never written. Writes
/// hold a claim for as long as their folder has no installed record, so a sweep never meets one half-done.
@MainActor
final class ExtensionFiles {
    /// Nil when installs load in place (tests without a store).
    let directory: URL?
    /// The clones unpacked extensions load from, beside `directory`: never taken for store copies.
    private let unpackedDirectory: URL?
    private var writesInFlight = 0

    init(directory: URL?) {
        self.directory = directory
        unpackedDirectory = directory?.deletingLastPathComponent().appendingPathComponent("UnpackedExtensions", isDirectory: true)
    }

    /// Whether `path` is a copy Lilo installed, which it may replace or delete.
    nonisolated func owns(_ path: String) -> Bool {
        directory.map { path.hasPrefix($0.path + "/") } ?? false
    }

    /// The folder WebKit loads the extension at `url` from, which preparation writes into: `url` itself for a copy Lilo
    /// installed, else an APFS clone of it, cloned again once any of its files changed. Safe off the main thread.
    nonisolated func workingCopy(of url: URL) throws -> URL {
        guard let unpackedDirectory, !owns(url.path) else { return url }
        let fm = FileManager.default
        let folder = url.resolvingSymlinksInPath()
        let clone = Self.unpackedClone(of: url, in: unpackedDirectory)
        let stampURL = clone.appendingPathComponent("_lilo/unpacked-source.txt")
        var hasher = SHA256()
        if let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                hasher.update(data: Data("\(file.path) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)\n".utf8))
            }
        }
        let stamp = Data(hasher.finalize().map { String(format: "%02x", $0) }.joined().utf8)
        if (try? Data(contentsOf: stampURL)) == stamp { return clone }

        try fm.createDirectory(at: unpackedDirectory, withIntermediateDirectories: true)
        let staged = unpackedDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try Self.clone(folder, to: staged)
        do {
            let stagedStamp = staged.appendingPathComponent("_lilo/unpacked-source.txt")
            try fm.createDirectory(at: stagedStamp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try stamp.write(to: stagedStamp)
            if fm.fileExists(atPath: clone.path) {
                _ = try fm.replaceItemAt(clone, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: clone)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return clone
    }

    /// Named from the canonical path, as a path-derived extension id is.
    private nonisolated static func unpackedClone(of url: URL, in unpackedDirectory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        return unpackedDirectory.appendingPathComponent(digest.prefix(8).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    /// An APFS clone shares the source's blocks until either side writes; another volume gets a full copy.
    nonisolated static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
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
        try Self.clone(url, to: staged)
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
        try Self.clone(extracted, to: staged)
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

    /// Deletes a copy Lilo installed, or the clone of an unpacked folder, which itself is left alone.
    func remove(_ path: String) {
        if owns(path) {
            try? FileManager.default.removeItem(atPath: path)
        } else if let unpackedDirectory {
            try? FileManager.default.removeItem(at: Self.unpackedClone(of: URL(fileURLWithPath: path, isDirectory: true), in: unpackedDirectory))
        }
    }

    /// Removes folders an interrupted uninstall, install or update left, and clones of unpacked extensions not loaded (any
    /// `keeping` does not name), restoring an update backup whose live copy is missing. Matched by folder name; skipped
    /// while a write is in flight, so the next restore sweeps.
    func sweep(keeping folderNames: Set<String>) {
        guard let directory, writesInFlight == 0 else { return }
        let fm = FileManager.default
        // Orphans are renamed away on the main actor, so an install starting later never loses files;
        // only the slow removal runs detached.
        var orphans: [URL] = []
        for directory in [directory, unpackedDirectory].compactMap({ $0 }) {
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !folderNames.contains(name) {
                let url = directory.appendingPathComponent(name, isDirectory: true)
                if name.hasPrefix("."), name.hasSuffix(".update-bak") {
                    let liveName = String(name.dropFirst().dropLast(".update-bak".count))
                    let live = directory.appendingPathComponent(liveName, isDirectory: true)
                    if folderNames.contains(liveName), !fm.fileExists(atPath: live.path), (try? fm.moveItem(at: url, to: live)) != nil { continue }
                }
                let doomed = directory.appendingPathComponent(".sweep-\(UUID().uuidString)", isDirectory: true)
                if (try? fm.moveItem(at: url, to: doomed)) != nil { orphans.append(doomed) }
            }
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
