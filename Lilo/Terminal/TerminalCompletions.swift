import Darwin
import Foundation

/// Shell commands offered in the command bar after ">": the user's history, most recent first, then
/// the programs on their PATH. History files are reparsed when they change, PATH folders rescanned
/// when one gains or loses a program.
actor TerminalCompletions {
    struct Item: Equatable, Sendable {
        enum Source: String, Sendable {
            case history, command
        }

        let command: String
        let source: Source
    }

    static let shared: TerminalCompletions = {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var files = [home.appendingPathComponent(".zsh_history"), home.appendingPathComponent(".bash_history")]
        if let zdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"] {
            files.insert(URL(fileURLWithPath: zdotdir).appendingPathComponent(".zsh_history"), at: 0)
        }
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        let fishHistory = dataHome.appendingPathComponent("fish/fish_history")
        let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) }
        if shell?.hasSuffix("/fish") == true { files.insert(fishHistory, at: 0) } else { files.append(fishHistory) }
        return TerminalCompletions(historyFiles: files)
    }()

    private static let historyLimit = 5_000
    private static let fallbackPath = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let historyFiles: [URL]
    private var historyStamps: [Date?] = []
    /// Unique single-line commands, most recent first.
    private var history: [String] = []

    private var pathDirectories: [String]?
    /// When the login shell may be asked for PATH again: one lookup at a time, and a minute after one that timed out.
    private var pathLookupDue = ContinuousClock.now
    private var programStamps: [Date?] = []
    /// Sorted, unique program names.
    private var programs: [String] = []

    /// `pathDirectories` nil reads PATH from the user's login shell, once, in the background.
    init(historyFiles: [URL], pathDirectories: [String]? = nil) {
        self.historyFiles = historyFiles
        self.pathDirectories = pathDirectories
    }

    /// Up to eight history lines starting with `query`, then (for a first word) programs starting
    /// with it. An empty query lists the most recent commands.
    func complete(_ query: String) -> [Item] {
        let limit = 8
        refreshHistory()
        var items: [Item] = []
        var seen: Set<String> = []
        for command in history where command.hasPrefix(query) {
            items.append(Item(command: command, source: .history))
            seen.insert(command)
            if items.count == limit { return items }
        }
        guard !query.isEmpty, !query.contains(" ") else { return items }
        refreshPrograms()
        var index = lowerBound(of: query)
        while index < programs.count, items.count < limit, programs[index].hasPrefix(query) {
            if !seen.contains(programs[index]) { items.append(Item(command: programs[index], source: .command)) }
            index += 1
        }
        return items
    }

    private func refreshHistory() {
        let stamps = historyFiles.map(Self.modificationDate)
        guard stamps != historyStamps else { return }
        historyStamps = stamps
        var seen: Set<String> = []
        history = []
        for file in historyFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            let commands = file.lastPathComponent == "fish_history"
                ? Self.parseFishHistory(data) : Self.parseHistory(data, zsh: file.lastPathComponent.contains("zsh"))
            for command in commands.reversed()
            where history.count < Self.historyLimit && seen.insert(command).inserted {
                history.append(command)
            }
        }
    }

    /// Commands in file order. zsh's extended format prefixes `: <time>:<duration>;`, and zsh stores
    /// some bytes metafied (0x83, then the byte xor 0x20). Multi-line commands are left out.
    static func parseHistory(_ data: Data, zsh: Bool) -> [String] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count)
        var meta = false
        for byte in data {
            if zsh, byte == 0x83 {
                meta = true
            } else {
                bytes.append(meta ? byte ^ 0x20 : byte)
                meta = false
            }
        }
        var commands: [String] = []
        var continued = false
        for slice in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let continues = slice.last == 0x5C
            defer { continued = continues }
            guard !continued, !continues, var line = String(bytes: slice, encoding: .utf8) else { continue }
            if zsh, line.hasPrefix(": "), let separator = line.firstIndex(of: ";") {
                line = String(line[line.index(after: separator)...])
            } else if !zsh, line.hasPrefix("#"), line.dropFirst().allSatisfy(\.isNumber) {
                continue
            }
            let command = line.trimmingCharacters(in: .whitespaces)
            if !command.isEmpty { commands.append(command) }
        }
        return commands
    }

    /// Fish escapes backslashes and newlines byte by byte; completions stay single-line.
    private static func parseFishHistory(_ data: Data) -> [String] {
        data.split(separator: 0x0A).compactMap { slice in
            guard slice.starts(with: "- cmd: ".utf8) else { return nil }
            var bytes = slice.dropFirst(7).makeIterator()
            var command: [UInt8] = []
            while let byte = bytes.next() {
                if byte == 0x5C {
                    guard bytes.next() == 0x5C else { return nil }
                }
                command.append(byte)
            }
            return command.isEmpty ? nil : String(bytes: command, encoding: .utf8)
        }
    }

    private func refreshPrograms() {
        guard let directories = pathDirectories else {
            // Until the login shell answers, completions come from history alone.
            if pathLookupDue <= .now {
                pathLookupDue = .now + .seconds(60)
                Task { if let path = await Self.loginPath() { pathDirectories = path } }
            }
            return
        }
        let stamps = directories.map { Self.modificationDate(URL(fileURLWithPath: $0)) }
        guard stamps != programStamps else { return }
        programStamps = stamps
        var names: Set<String> = []
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in entries where !name.hasPrefix(".") && !names.contains(name) {
                let path = directory + "/" + name
                var info = stat()
                if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 {
                    names.insert(name)
                }
            }
        }
        programs = names.sorted()
    }

    private func lowerBound(of query: String) -> Int {
        var low = 0
        var high = programs.count
        while low < high {
            let middle = (low + high) / 2
            if programs[middle] < query { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The login shell's PATH (where Homebrew and version managers add themselves), then the usual
    /// folders, without duplicates. A login shell that hangs is stopped after a few seconds: nil, worth a retry.
    private static func loginPath() async -> [String]? {
        let path = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                guard (try? process.run()) != nil else { return continuation.resume(returning: "") }
                guard exited.wait(timeout: .now() + 3) == .success else {
                    process.terminate()
                    return continuation.resume(returning: nil)
                }
                // A background job of the profile may hold the pipe open: take what is there, never wait for its end.
                let reader = output.fileHandleForReading.fileDescriptor
                _ = fcntl(reader, F_SETFL, O_NONBLOCK)
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(reader, &buffer, buffer.count)
                continuation.resume(returning: count > 0 ? String(bytes: buffer[..<count], encoding: .utf8) ?? "" : "")
            }
        }
        guard let path else { return nil }
        var seen: Set<String> = []
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (path.split(separator: ":").map(String.init) + inherited + fallbackPath).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
