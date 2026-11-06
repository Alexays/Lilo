import Foundation

/// The files of a conversation's project, for `@` in the composer: listed once and kept for a short while,
/// so typing a query never walks the disk again.
actor ConversationProjectFiles {
    /// The last project listed, each path with its lowercased form and name, so a keystroke only compares.
    private var cached: (directory: String, files: [(path: String, lower: String, name: Substring)], at: Date)?
    private static let maxAge: TimeInterval = 30
    private static let maxFiles = 50_000

    /// The project's files matching `query`, best first: the name containing it, then the path, then its
    /// letters in order. Paths are relative to `directory`.
    func search(_ query: String, in directory: String) -> [String] {
        let files = listing(of: directory)
        let needle = query.lowercased()
        guard !needle.isEmpty else { return files.prefix(20).map(\.path) }
        var ranked: [(rank: Int, path: String)] = []
        for file in files {
            let rank: Int
            if file.name.hasPrefix(needle) { rank = 0 } else if file.name.contains(needle) { rank = 1 } else if file.lower.contains(needle) { rank = 2 } else if Self.inOrder(needle, in: file.lower) { rank = 3 } else { continue }
            ranked.append((rank, file.path))
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.path.count < $1.path.count }.prefix(20).map(\.path)
    }

    private static func inOrder(_ needle: String, in haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }

    /// Git's view of the project when it is a repository (tracked and untracked, ignored left out), else a walk
    /// that skips hidden folders.
    private func listing(of directory: String) -> [(path: String, lower: String, name: Substring)] {
        if let cached, cached.directory == directory, Date().timeIntervalSince(cached.at) < Self.maxAge { return cached.files }
        var paths: [String] = []
        if GitDiff.repositoryRoot(containing: directory) != nil,
           let output = GitDiff.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: directory) {
            paths = output.split(separator: 0).prefix(Self.maxFiles).compactMap { String(bytes: $0, encoding: .utf8) }
        } else if let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            let base = URL(fileURLWithPath: directory).standardizedFileURL.path.count + 1
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                paths.append(String(url.standardizedFileURL.path.dropFirst(base)))
                if paths.count >= Self.maxFiles { break }
            }
        }
        let files = paths.map { path in
            let lower = path.lowercased()
            return (path: path, lower: lower, name: lower.split(separator: "/").last ?? lower[...])
        }
        cached = (directory, files, Date())
        return files
    }
}
