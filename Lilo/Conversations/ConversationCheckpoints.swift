import Foundation

/// The project's files at a point of a conversation, as a git tree written through a throwaway index:
/// untracked files included, ignored ones left out, and neither the user's index nor their working tree
/// touched to take it. Runs off the main thread.
enum ConversationCheckpoints {
    /// The tree of every file in the repository holding `directory`, or nil outside a repository.
    static func snapshot(in directory: String) -> String? {
        guard let root = GitDiff.repositoryRoot(containing: directory) else { return nil }
        return withIndex { index in
            // Seeded with the user's index, `add -A` hashes only the files changed since: never the whole project.
            try? FileManager.default.copyItem(atPath: GitDiff.gitDirectories(of: root).own + "/index", toPath: index["GIT_INDEX_FILE"] ?? "")
            guard GitDiff.run(["add", "-A"], in: root, environment: index) != nil,
                  let tree = GitDiff.run(["write-tree"], in: root, environment: index) else { return nil }
            return String(decoding: tree, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Puts every file back as it was in `tree`, removing the files made since.
    static func restore(_ tree: String, in directory: String) -> Bool {
        guard let root = GitDiff.repositoryRoot(containing: directory), let current = snapshot(in: directory) else { return false }
        if let added = GitDiff.run(["diff", "--name-only", "-z", "--diff-filter=A", tree, current], in: root) {
            for path in added.split(separator: 0) {
                try? FileManager.default.removeItem(atPath: root + "/" + String(decoding: path, as: UTF8.self))
            }
        }
        return withIndex { index in
            GitDiff.run(["read-tree", tree], in: root, environment: index) != nil
                && GitDiff.run(["checkout-index", "-a", "-f"], in: root, environment: index) != nil
        }
    }

    /// Puts one file back as it was in `tree`, or removes it when it did not exist then.
    static func restoreFile(_ path: String, from tree: String, in directory: String) -> Bool {
        guard let root = GitDiff.repositoryRoot(containing: directory) else { return false }
        let absolute = path.hasPrefix("/") ? path : directory + "/" + path
        let resolved = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard resolved.hasPrefix(root + "/") else { return false }
        let relative = String(resolved.dropFirst(root.count + 1))
        guard let content = GitDiff.run(["cat-file", "blob", "\(tree):\(relative)"], in: root) else {
            return (try? FileManager.default.removeItem(atPath: resolved)) != nil
        }
        return (try? content.write(to: URL(fileURLWithPath: resolved))) != nil
    }

    /// Lines added and removed in the project since `tree`, files made since included.
    static func stat(since tree: String, in directory: String) -> (added: Int, removed: Int)? {
        guard let root = GitDiff.repositoryRoot(containing: directory), let current = snapshot(in: directory),
              let output = GitDiff.run(["diff", "--numstat", tree, current], in: root) else { return nil }
        var added = 0, removed = 0
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t")
            // Binary files show "-": they change no line.
            guard fields.count >= 2 else { continue }
            added += Int(fields[0]) ?? 0
            removed += Int(fields[1]) ?? 0
        }
        return (added, removed)
    }

    private static func withIndex<T>(_ body: ([String: String]) -> T) -> T {
        let index = FileManager.default.temporaryDirectory.appending(path: "lilo-checkpoint-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: index) }
        return body(["GIT_INDEX_FILE": index])
    }
}
