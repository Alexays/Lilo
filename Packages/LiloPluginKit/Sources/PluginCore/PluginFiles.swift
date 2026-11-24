import Foundation

/// The `files:plugin-dir` surface: read, write and list strictly inside one plugin's support
/// folder. A path is relative; absolute paths, `..` and symlinks that leave the folder reject.
public struct PluginFiles: Sendable {
    /// Larger files stay out of the ndjson channel.
    public static let maxBytes = 4 * 1024 * 1024

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
    }

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func read(_ path: String) throws -> String {
        let url = try resolve(path)
        guard let data = try? Data(contentsOf: url) else { throw PluginRequestError.invalidParams("Cannot read \"\(path)\"") }
        guard data.count <= Self.maxBytes, let text = String(data: data, encoding: .utf8) else {
            throw PluginRequestError.invalidParams("\"\(path)\" is not UTF-8 text under \(Self.maxBytes) bytes")
        }
        return text
    }

    public func write(_ path: String, content: String) throws {
        guard content.utf8.count <= Self.maxBytes else {
            throw PluginRequestError.invalidParams("Content is over \(Self.maxBytes) bytes")
        }
        let url = try resolve(path)
        guard url != root.resolvingSymlinksInPath() else { throw PluginRequestError.invalidParams("\"\(path)\" is a folder") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            throw PluginRequestError.invalidParams("Cannot write \"\(path)\"")
        }
    }

    /// The folder's entries by name; an empty `path` lists the support folder itself.
    public func list(_ path: String = "") throws -> [Entry] {
        let url = try resolve(path)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            throw PluginRequestError.invalidParams("Cannot list \"\(path)\"")
        }
        return names.sorted().map { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return Entry(name: name, isDirectory: isDirectory.boolValue)
        }
    }

    /// `path` under the root, with symlinks resolved: a result outside the root rejects.
    func resolve(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !path.contains("\0"), !parts.contains("..") else {
            throw PluginRequestError.invalidParams("Path must stay inside the plugin's folder")
        }
        let base = root.resolvingSymlinksInPath()
        // Resolve the deepest existing ancestor (lstat, so a dangling symlink counts), then append the rest:
        // a write may name folders and a file that do not exist yet.
        var existing = parts.reduce(base) { $0.appendingPathComponent(String($1)) }
        var tail: [String] = []
        while existing.path != base.path, (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let url = tail.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        guard url.path == base.path || url.path.hasPrefix(base.path + "/") else {
            throw PluginRequestError.invalidParams("Path must stay inside the plugin's folder")
        }
        return url
    }
}
