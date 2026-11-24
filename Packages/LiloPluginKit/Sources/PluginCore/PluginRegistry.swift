import Foundation

/// One plugin folder's load outcome. A rejected manifest still gets a row (`rejectionReason`
/// set, never started); its `id`/`title` fall back to the folder name.
public struct PluginRecord: Equatable, Sendable {
    public var id: String { manifest?.id ?? folder.lastPathComponent }
    public let folder: URL
    /// Loaded from the bundled root rather than the user plugins folder.
    public let bundled: Bool
    public let manifest: PluginManifest?
    public let rejectionReason: String?
    /// The plugin's own support folder, created lazily when the `files:plugin-dir` capability lands.
    public let supportDirectory: URL

    public var valid: Bool { manifest != nil && rejectionReason == nil }
    /// `icon.png` or `icon.svg` at the folder's root, as a data URL for the panel.
    public var iconDataURL: String? {
        for name in ["icon.png", "icon.svg"] {
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }
            let mime = name.hasSuffix(".svg") ? "image/svg+xml" : "image/png"
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return nil
    }
}

/// Scans the plugin roots on demand and diffs the snapshot against the last scan.
/// No folder watching: a rescan is a few `stat`s and callers decide when to run it.
public actor PluginRegistry {
    /// The roots a plugin folder may live under, scanned in order; `bundled` roots are
    /// read-only. The first record with a manifest id wins, so user roots shadow bundled ones.
    public struct Root: Sendable, Equatable {
        public let url: URL
        public let bundled: Bool
        public init(url: URL, bundled: Bool) {
            self.url = url
            self.bundled = bundled
        }
    }

    public struct ScanResult: Equatable, Sendable {
        public let records: [PluginRecord]
        /// Plugin folders whose fingerprint changed since the last scan (added, modified or removed).
        public let changedFolders: Set<URL>
        public var changed: Bool { !changedFolders.isEmpty }
    }

    private struct Fingerprint: Equatable {
        var manifestModified: Date
        var manifestSize: Int
        var entryModified: Date?
        var entrySize: Int?
    }

    public let roots: [Root]
    /// `files:plugin-dir` support folders live under here, one per plugin id.
    public let supportRoot: URL
    private var fingerprints: [URL: Fingerprint] = [:]
    public private(set) var records: [PluginRecord] = []

    public init(roots: [Root], supportRoot: URL) {
        self.roots = roots
        self.supportRoot = supportRoot
    }

    public init(userRoot: URL, bundledRoot: URL, supportRoot: URL) {
        self.init(roots: [Root(url: userRoot, bundled: false), Root(url: bundledRoot, bundled: true)], supportRoot: supportRoot)
    }

    public func record(id: String) -> PluginRecord? {
        records.first { $0.id == id }
    }

    /// Rescans every root; `changedFolders` names the plugin folders that differ.
    @discardableResult
    public func rescan() -> ScanResult {
        var records: [PluginRecord] = []
        var fingerprints: [URL: Fingerprint] = [:]
        var seenIDs: Set<String> = []
        for root in roots {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for folder in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let manifestFile = folder.appendingPathComponent(PluginManifest.fileName)
                guard let manifestAttrs = try? manifestFile.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = manifestAttrs.contentModificationDate, let size = manifestAttrs.fileSize else { continue }
                var manifest: PluginManifest?
                var rejection: String?
                do {
                    manifest = try PluginManifest.load(at: folder)
                } catch let error as PluginManifestError {
                    rejection = error.reason
                } catch {
                    rejection = error.localizedDescription
                }
                // A manifest id the user root already claimed is shadowed here.
                if let manifest, !seenIDs.insert(manifest.id).inserted { continue }
                let entry = manifest.map { folder.appendingPathComponent($0.entry).standardizedFileURL }
                let entryAttrs = entry.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) }
                let id = manifest?.id ?? folder.lastPathComponent
                records.append(PluginRecord(
                    folder: folder, bundled: root.bundled, manifest: manifest, rejectionReason: rejection,
                    supportDirectory: supportRoot.appendingPathComponent(id, isDirectory: true)
                ))
                fingerprints[folder] = Fingerprint(
                    manifestModified: modified, manifestSize: size,
                    entryModified: entryAttrs?.contentModificationDate, entrySize: entryAttrs?.fileSize
                )
            }
        }
        let changedFolders = Set(fingerprints.keys).symmetricDifference(self.fingerprints.keys)
            .union(Set(fingerprints.keys.filter { fingerprints[$0] != self.fingerprints[$0] }))
        self.records = records
        self.fingerprints = fingerprints
        return ScanResult(records: records, changedFolders: changedFolders)
    }
}
