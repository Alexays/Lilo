import Foundation
import OSLog

/// A repository's changes as git prints them, parsed once into line records over the raw output:
/// no String exists for a line until it is drawn.
struct GitDiff: Sendable {
    enum Mode: Sendable {
        /// The working tree and the index against HEAD.
        case uncommitted
        /// The working tree against the merge base with the default branch, as a pull request shows it.
        case branch
    }

    enum LineKind: UInt8, Sendable {
        case context, added, removed, hunk
    }

    struct Line: Sendable {
        var kind: LineKind
        /// The text in `bytes`, past the +, - or space git puts first; a hunk keeps its whole header.
        var start: Int32
        var length: Int32
        /// 0 for an added line, and for a hunk header.
        var oldNumber: Int32
        /// 0 for a removed line, and for a hunk header.
        var newNumber: Int32
    }

    enum Status: Sendable {
        case modified, added, deleted, renamed
    }

    struct File: Sendable {
        var path: String
        var oldPath: String?
        var status = Status.modified
        var isBinary = false
        var added = 0
        var removed = 0
        /// Indices into `lines`.
        var lines: Range<Int> = 0..<0

        /// An image AppKit can show, whose two versions the diff draws instead of its bytes.
        var isImage: Bool {
            isBinary && GitDiff.imageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "tiff", "tif", "bmp", "ico"]

    var bytes: [UInt8] = []
    var lines: [Line] = []
    var files: [File] = []
    /// The branch compared against in branch mode, and its merge base with HEAD (short).
    var base: String?
    var mergeBase: String?
    /// The commit the working tree is compared with, and the repository's root: where both
    /// versions of a file are read from.
    var target: String?
    var root: String?

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }

    func text(of line: Line) -> ArraySlice<UInt8> {
        bytes[Int(line.start)..<Int(line.start + line.length)]
    }

    // MARK: - Loading

    /// Runs git in `directory` and parses its output, untracked files included. Blocks: call it off
    /// the main thread. Nil when git fails or `directory` is not in a repository.
    static func load(in directory: String, mode: Mode) -> GitDiff? {
        var diff = GitDiff()
        let target: String
        switch mode {
        case .uncommitted:
            target = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory) != nil ? "HEAD" : emptyTree
        case .branch:
            guard let base = defaultBranch(in: directory),
                  let output = run(["merge-base", base, "HEAD"], in: directory) else { return nil }
            target = (String(bytes: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            diff.base = base
            diff.mergeBase = String(target.prefix(7))
        }
        guard let output = run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", "--unified=3", target], in: directory) else { return nil }
        diff.target = target
        diff.root = repositoryRoot(containing: directory)
        diff.bytes = [UInt8](output)
        diff.parse()
        diff.appendUntracked(in: directory)
        return diff
    }

    /// Lines added and removed against HEAD, untracked files counted as added: what the terminal
    /// row shows. Blocks; nil outside a repository or before the first commit.
    static func stat(in directory: String) -> (added: Int, removed: Int)? {
        guard let output = run(["diff", "--numstat", "--no-ext-diff", "--no-textconv", "HEAD"], in: directory) else { return nil }
        var added = 0, removed = 0
        // "added<TAB>removed<TAB>path" per file; a binary file shows "-" for both.
        for row in [UInt8](output).split(separator: UInt8(ascii: "\n")) {
            let fields = row.split(separator: UInt8(ascii: "\t"), maxSplits: 2)
            guard fields.count == 3 else { continue }
            added += parseInt(fields[0])
            removed += parseInt(fields[1])
        }
        guard let root = repositoryRoot(containing: directory) else { return (added, removed) }
        var budget = untrackedReadBudget
        for path in untrackedPaths(in: root) {
            guard let content = readText(path, in: root, budget: &budget) else { continue }
            added += content.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 } + (content.isEmpty || content.last == UInt8(ascii: "\n") ? 0 : 1)
        }
        return (added, removed)
    }

    /// The folder holding the repository `directory` is in, found without running git.
    static func repositoryRoot(containing directory: String) -> String? {
        var folder = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder.path }
            if folder.path == "/" { return nil }
            folder.deleteLastPathComponent()
        }
    }

    /// Where git keeps the data of the repository at `root`, read from disk without running git:
    /// `own` holds its HEAD and index, `common` the refs. They differ only in a linked worktree.
    static func gitDirectories(of root: String) -> (own: String, common: String) {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        // A linked worktree or a submodule has a .git file naming its real git directory.
        guard let link = try? String(contentsOf: dotGit, encoding: .utf8), link.hasPrefix("gitdir: ") else {
            return (dotGit.path, dotGit.path)
        }
        let own = URL(fileURLWithPath: link.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines),
                      relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL
        guard let common = try? String(contentsOf: own.appendingPathComponent("commondir"), encoding: .utf8) else {
            return (own.path, own.path)
        }
        let commonURL = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: own.appendingPathComponent(""))
        return (own.path, commonURL.standardizedFileURL.path)
    }

    /// The roots of every worktree of the repository `directory` is in, the main one first, those
    /// whose folder is gone left out. Blocks; empty when git fails.
    static func worktrees(of directory: String) -> [String] {
        guard let output = run(["worktree", "list", "--porcelain"], in: directory) else { return [] }
        // Blank-line separated records, each opening with "worktree <path>"; a bare one has a "bare" line.
        return (String(bytes: output, encoding: .utf8) ?? "").components(separatedBy: "\n\n").compactMap { record in
            let lines = record.split(separator: "\n")
            guard let first = lines.first, first.hasPrefix("worktree "), !lines.contains("bare") else { return nil }
            let path = String(first.dropFirst("worktree ".count))
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }

    /// The remote's default branch, else a local or remote main or master.
    private static func defaultBranch(in directory: String) -> String? {
        if let output = run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: directory) {
            let name = (String(bytes: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return ["main", "master", "origin/main", "origin/master"].first {
            run(["rev-parse", "--verify", "--quiet", "\($0)^{commit}"], in: directory) != nil
        }
    }

    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    private static let timeout: TimeInterval = 10

    private static let executable: URL? = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }

    /// Git's standard output, or nil when it exits with an error or outlives `timeout`.
    static func run(_ arguments: [String], in directory: String, environment extra: [String: String] = [:]) -> Data? {
        guard let executable else { return nil }
        let signpost = PerfSignposts.energy.beginInterval("git", id: PerfSignposts.energy.makeSignpostID(), "\(arguments.first ?? "")")
        defer { PerfSignposts.energy.endInterval("git", signpost) }
        let process = Process()
        process.executableURL = executable
        // The repository is any folder the terminal enters: its config must not get git to run a program.
        process.arguments = ["-c", "core.quotePath=false", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"]
            + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        // Reading never takes the index lock, so it never fails a git command the user runs meanwhile.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment.merge(extra) { $1 }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A stalled mount or a hung git would otherwise block the read below forever.
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: a full pipe would block git forever.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: - Parsing

    private mutating func parse() {
        var file: File?
        var oldLine: Int32 = 0, newLine: Int32 = 0
        var oldLeft = 0, newLeft = 0
        lines.reserveCapacity(bytes.count / 40)

        func finish(_ file: File?, _ files: inout [File], end: Int) {
            guard var file else { return }
            file.lines = file.lines.lowerBound..<end
            files.append(file)
        }

        var start = 0
        let count = bytes.count
        while start < count {
            var end = start
            while end < count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            let length = end - start
            defer { start = end + 1 }
            guard length > 0 else { continue }
            let first = bytes[start]

            // Inside a hunk the counts decide, so a removed "--- x" line is never read as a header.
            if oldLeft > 0 || newLeft > 0 {
                let text = Int32(start + 1), textLength = Int32(length - 1)
                switch first {
                case UInt8(ascii: "+"):
                    lines.append(Line(kind: .added, start: text, length: textLength, oldNumber: 0, newNumber: newLine))
                    newLine += 1; newLeft -= 1
                    file?.added += 1
                case UInt8(ascii: "-"):
                    lines.append(Line(kind: .removed, start: text, length: textLength, oldNumber: oldLine, newNumber: 0))
                    oldLine += 1; oldLeft -= 1
                    file?.removed += 1
                case UInt8(ascii: " "):
                    lines.append(Line(kind: .context, start: text, length: textLength, oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                default:
                    break   // "\ No newline at end of file"
                }
                continue
            }

            let line = bytes[start..<end]
            if line.starts(with: Self.diffHeader) {
                finish(file, &files, end: lines.count)
                file = File(path: Self.headerPath(line), lines: lines.count..<lines.count)
            } else if line.starts(with: Self.hunkHeader) {
                let numbers = Self.hunkNumbers(line)
                oldLine = numbers.old; oldLeft = numbers.oldCount
                newLine = numbers.new; newLeft = numbers.newCount
                lines.append(Line(kind: .hunk, start: Int32(start), length: Int32(length), oldNumber: 0, newNumber: 0))
            } else if line.starts(with: Self.newFile) {
                file?.status = .added
            } else if line.starts(with: Self.deletedFile) {
                file?.status = .deleted
            } else if line.starts(with: Self.renameFrom) {
                file?.status = .renamed
                file?.oldPath = Self.unquote(line.dropFirst(Self.renameFrom.count))
            } else if line.starts(with: Self.renameTo) {
                file?.path = Self.unquote(line.dropFirst(Self.renameTo.count))
            } else if line.starts(with: Self.newPath), !line.suffix(Self.devNull.count).elementsEqual(Self.devNull) {
                file?.path = Self.unquote(line.dropFirst(Self.newPath.count))
            } else if line.starts(with: Self.oldPath), file?.status == .deleted {
                file?.path = Self.unquote(line.dropFirst(Self.oldPath.count))
            } else if line.starts(with: Self.binaryFiles) {
                file?.isBinary = true
            }
        }
        finish(file, &files, end: lines.count)
    }

    private static let diffHeader = Array("diff --git ".utf8)
    private static let hunkHeader = Array("@@ ".utf8)
    private static let newFile = Array("new file mode".utf8)
    private static let deletedFile = Array("deleted file mode".utf8)
    private static let renameFrom = Array("rename from ".utf8)
    private static let renameTo = Array("rename to ".utf8)
    private static let oldPath = Array("--- a/".utf8)
    private static let newPath = Array("+++ b/".utf8)
    private static let devNull = Array("/dev/null".utf8)
    private static let binaryFiles = Array("Binary files ".utf8)

    /// "@@ -12,7 +12,9 @@ context": a missing count means one line.
    private static func hunkNumbers(_ line: ArraySlice<UInt8>) -> (old: Int32, oldCount: Int, new: Int32, newCount: Int) {
        var index = line.startIndex + 3
        func number() -> Int {
            var value = 0
            while index < line.endIndex, line[index] >= UInt8(ascii: "0"), line[index] <= UInt8(ascii: "9") {
                value = value * 10 + Int(line[index] - UInt8(ascii: "0"))
                index += 1
            }
            return value
        }
        func range() -> (start: Int, count: Int) {
            index += 1   // the - or +
            let start = number()
            guard index < line.endIndex, line[index] == UInt8(ascii: ",") else { return (start, 1) }
            index += 1
            return (start, number())
        }
        let old = range()
        index += 1   // the space between the two ranges
        let new = range()
        return (Int32(old.start), old.count, Int32(new.start), new.count)
    }

    /// "diff --git a/P b/P", each side quoted when it needs to be. Unrenamed, the two sides are the
    /// same length, so the path is the second half whatever it holds (" b/" included): a binary file has
    /// no "+++" line to correct it. A rename's own lines name its paths.
    private static func headerPath(_ line: ArraySlice<UInt8>) -> String {
        let sides = line.dropFirst(diffHeader.count)
        if sides.count % 2 == 1 {
            let newSide = unquote(sides.suffix(sides.count / 2))
            if newSide.hasPrefix("b/") { return String(newSide.dropFirst(2)) }
        }
        let text = String(bytes: sides, encoding: .utf8) ?? ""
        return text.range(of: " b/", options: .backwards).map { String(text[$0.upperBound...]) } ?? ""
    }

    /// Git quotes a path holding a quote, a backslash or a control character.
    private static func unquote(_ bytes: ArraySlice<UInt8>) -> String {
        let text = (String(bytes: bytes, encoding: .utf8) ?? "")
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseInt(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { value, byte in
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") ? value * 10 + Int(byte - UInt8(ascii: "0")) : value
        }
    }

    // MARK: - Images

    /// The bytes of `file` as it was at the compared commit; nil for an added file. Blocks.
    func oldContent(of file: File) -> Data? {
        guard file.status != .added, let target, let root else { return nil }
        // A path after "rev:" is read from the repository's root, whatever folder git runs in.
        return Self.run(["show", "\(target):\(file.oldPath ?? file.path)"], in: root)
    }

    /// The bytes of `file` in the working tree; nil for a deleted file. Blocks.
    func newContent(of file: File) -> Data? {
        guard file.status != .deleted, let root else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(file.path))
    }

    // MARK: - Untracked files

    /// What the untracked files of one load may read in all; past it they show without content.
    private static let untrackedReadBudget = 8 << 20
    private static let untrackedFileLimit = 1 << 20

    private static func untrackedPaths(in directory: String) -> [String] {
        guard let output = run(["ls-files", "--others", "--exclude-standard", "-z"], in: directory) else { return [] }
        // A nested repository or worktree shows as its folder, with a trailing slash: it is not a file.
        return output.split(separator: 0).filter { $0.last != UInt8(ascii: "/") }.map { (String(bytes: $0, encoding: .utf8) ?? "") }
    }

    /// A small text file's bytes, `path` relative to `root`; nil for a binary or large one, or once
    /// `budget` is spent.
    private static func readText(_ path: String, in root: String, budget: inout Int) -> [UInt8]? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= untrackedFileLimit, size <= budget,
              let data = try? Data(contentsOf: url) else { return nil }
        budget -= size
        let bytes = [UInt8](data)
        // Git's own test for binary content: a NUL in the first 8000 bytes.
        return bytes.prefix(8000).contains(0) ? nil : bytes
    }

    private mutating func appendUntracked(in directory: String) {
        // ls-files lists paths relative to the directory it runs in: run it from the root.
        guard let root = Self.repositoryRoot(containing: directory) else { return }
        var budget = Self.untrackedReadBudget
        for path in Self.untrackedPaths(in: root) {
            var file = File(path: path, status: .added, lines: lines.count..<lines.count)
            if let content = Self.readText(path, in: root, budget: &budget) {
                let offset = bytes.count
                bytes.append(contentsOf: content)
                var start = 0, number: Int32 = 1
                while start < content.count {
                    var end = start
                    while end < content.count, content[end] != UInt8(ascii: "\n") { end += 1 }
                    lines.append(Line(kind: .added, start: Int32(offset + start), length: Int32(end - start), oldNumber: 0, newNumber: number))
                    number += 1
                    start = end + 1
                }
                file.added = Int(number - 1)
            } else {
                file.isBinary = true
            }
            file.lines = file.lines.lowerBound..<lines.count
            files.append(file)
        }
    }
}
