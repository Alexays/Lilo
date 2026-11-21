import AppKit
import Foundation

/// Registers `lilo-mcp` with the agents people run, each in its own configuration file, as `HarnessDefinition` says.
enum AgentClientConfig {
    typealias Client = HarnessDefinition

    /// The MCP server the agents launch: a pipe to Lilo's agent socket, shipped next to Lilo's own binary.
    static var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/lilo-mcp").path
    }

    static var genericConfigJSON: String {
        json(["mcpServers": ["lilo": ["command": helperPath]]])
    }

    /// Writes the client's configuration and says what it did, for the settings page.
    static func connect(_ client: Client, home: URL) async throws -> String {
        switch client.config {
        case .claudeCLI:
            // Its installers' places first: Lilo, started from the Finder, has no terminal PATH, and a login
            // shell leaves out what .zshrc adds (~/.local/bin included).
            guard let claude = await claudeBinary(client, home: home) else {
                throw unsafe AgentToolError(String(format: "Claude Code is not installed. Once it is, run: %@".localized, "claude mcp add --scope user lilo -- \(helperPath)"))
            }
            // `add` refuses a name already taken, by this Lilo or one that moved.
            _ = await run(claude, ["mcp", "remove", "--scope", "user", "lilo"], timeout: 15)
            let added = await run(claude, ["mcp", "add", "--scope", "user", "lilo", "--", helperPath], timeout: 15)
            guard added.status == 0 else { throw unsafe AgentToolError(String(format: "Claude Code refused the server: %@".localized, added.output ?? "")) }
        case .json, .toml:
            try register(client, home: home)
        }
        return client.added()
    }

    /// Takes Lilo's server out of the client's configuration, leaving its other servers and keys. Nothing to do
    /// when it was never there.
    static func remove(_ client: Client, home: URL) async throws {
        if case .claudeCLI = client.config {
            guard let claude = await claudeBinary(client, home: home) else { return }
            _ = await run(claude, ["mcp", "remove", "--scope", "user", "lilo"], timeout: 15)
        } else if let change = try edit(client, home: home, remove: true) {
            try write(Data(change.after.utf8), to: change.url)
        }
    }

    /// What Connect or Remove will do, before it does it: the file it touches and the lines that change, or for
    /// Claude Code the command it runs. `after` is the file's exact content once written.
    struct Preview: Equatable {
        struct Line: Equatable {
            /// In the file as it is (`-`) or as it will be (`+`).
            let number: Int
            let removed: Bool
            let text: String
        }

        let path: String
        let command: String?
        let lines: [Line]
        let after: String
        /// What to paste by hand where Lilo cannot write the file.
        let snippet: String
        /// Why Lilo will not write: the file exists and is not one it can merge into.
        let blocked: String?
    }

    static func preview(_ client: Client, home: URL, remove: Bool = false) -> Preview {
        let display = "~/" + client.config.path
        let snippet = remove ? "" : manualSnippet(client)
        if case .claudeCLI = client.config {
            let command = remove ? "claude mcp remove --scope user lilo" : "claude mcp add --scope user lilo -- \(helperPath)"
            return Preview(path: display, command: command, lines: [], after: "", snippet: snippet, blocked: nil)
        }
        do {
            guard let change = try edit(client, home: home, remove: remove) else {
                return Preview(path: display, command: nil, lines: [], after: "", snippet: snippet, blocked: nil)
            }
            return Preview(path: display, command: nil, lines: diff(change.before, change.after), after: change.after, snippet: snippet, blocked: nil)
        } catch {
            return Preview(path: display, command: nil, lines: [], after: "", snippet: snippet, blocked: error.localizedDescription)
        }
    }

    /// What the user pastes into the client's file themselves.
    private static func manualSnippet(_ client: Client) -> String {
        switch client.config {
        case .claudeCLI: "claude mcp add --scope user lilo -- \(helperPath)"
        case .json(_, let key, let entry): json([key: ["lilo": entry.value(helperPath)]])
        case .toml: tomlTable
        }
    }

    /// Points configurations at this Lilo again when it moved since they were written; returns the
    /// clients it fixed. Claude Code keeps its own store, which only its CLI edits.
    @discardableResult
    static func repairMovedConfigs(home: URL) -> [Client] {
        Client.all.filter { client in
            guard let command = serverCommand(of: client, home: home), command != helperPath,
                  !FileManager.default.fileExists(atPath: command) else { return false }
            return (try? register(client, home: home)) != nil
        }
    }

    /// The clients whose entry names a Lilo at another path (moved, or a second copy): Connect repoints them.
    static func staleClients(home: URL) -> [Client] {
        Client.all.filter { client in serverCommand(of: client, home: home).map { $0 != helperPath } ?? false }
    }

    /// The clients whose configuration names Lilo's server. Reads their files, so off the main thread.
    static func connectedClients(home: URL) -> [Client] {
        Client.all.filter { client in
            let url = home.appending(path: client.config.path)
            if case .toml = client.config {
                return (try? String(contentsOf: url, encoding: .utf8)).flatMap { liloTable(in: $0) } != nil
            }
            return liloServer(of: client, readJSON(url)) != nil
        }
    }

    /// The app whose icon stands for the client: its own, or Terminal for a command-line tool. nil when
    /// the client does not look installed; a tool installed elsewhere still left its folder in the home.
    static func iconApp(of client: Client, home: URL) -> URL? {
        let workspace = NSWorkspace.shared
        let detect = client.detect
        if let id = detect.bundleID, let app = workspace.urlForApplication(withBundleIdentifier: id) { return app }
        let found = detect.binary.flatMap { binary($0, home: home, extra: detect.binaryExtra) } != nil
            || detect.folders.contains { FileManager.default.fileExists(atPath: home.appending(path: $0).path) }
        return found ? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") : nil
    }

    private static func claudeBinary(_ client: Client, home: URL) async -> String? {
        guard let name = client.detect.binary else { return nil }
        let installed = binary(name, home: home, extra: client.detect.binaryExtra)
        let found = installed == nil ? await run("/bin/zsh", ["-lc", "command -v \(name)"], timeout: 5).output : installed
        return found.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func binary(_ name: String, home: URL, extra: [String]) -> String? {
        ([home.appending(path: ".local/bin/\(name)").path] + extra.map { home.appending(path: $0).path }
            + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"])
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Adds or replaces Lilo's entry in a client that keeps it in a file Lilo writes.
    private static func register(_ client: Client, home: URL) throws {
        if let change = try edit(client, home: home, remove: false) { try write(Data(change.after.utf8), to: change.url) }
    }

    /// The file a client keeps Lilo's server in, as it is and as Connect or Remove leaves it; nil when there is
    /// nothing to change. The one place the new content is made, so the preview is what gets written.
    private static func edit(_ client: Client, home: URL, remove: Bool) throws -> (url: URL, before: String, after: String)? {
        switch client.config {
        case .claudeCLI:
            return nil
        case .json(let path, let key, let entry):
            let url = home.appending(path: path)
            let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var config: [String: Any] = [:]
            // An empty file is a fresh one; anything else must parse as strict JSON, or comments would be lost.
            if FileManager.default.fileExists(atPath: url.path), !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let data = try? Data(contentsOf: url), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    if remove { return nil }
                    throw unsafe AgentToolError(String(format: "Lilo could not read %@: add this server to it yourself: %@".localized, url.path, manualSnippet(client)))
                }
                config = object
            }
            var servers = config[key] as? [String: Any] ?? [:]
            if remove {
                guard servers.removeValue(forKey: "lilo") != nil else { return nil }
            } else {
                servers["lilo"] = entry.value(helperPath)
            }
            config[key] = servers
            return (url, before, json(config))
        case .toml(let path):
            let url = home.appending(path: path)
            var text = ""
            if FileManager.default.fileExists(atPath: url.path) {
                guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                    if remove { return nil }
                    throw unsafe AgentToolError(String(format: "Lilo could not read %@: add this server to it yourself: %@".localized, url.path, tomlTable))
                }
                text = existing
            }
            let before = text
            if remove {
                guard let range = liloTable(in: text) else { return nil }
                text.removeSubrange(range)
            } else if let range = liloTable(in: text) {
                text.replaceSubrange(range, with: tomlTable)
            } else {
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += (text.isEmpty ? "" : "\n") + tomlTable
            }
            return (url, before, text)
        }
    }

    /// The `command` a client has for Lilo's server in a file Lilo writes, nil for Claude Code, whose store
    /// only its CLI edits.
    private static func serverCommand(of client: Client, home: URL) -> String? {
        let url = home.appending(path: client.config.path)
        if case .claudeCLI = client.config { return nil }
        if case .toml = client.config {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let range = liloTable(in: text) else { return nil }
            return text[range].split(separator: "\n").first(where: { $0.hasPrefix("command") })?
                .split(separator: "\"").dropFirst().first.map(String.init)
        }
        guard let server = liloServer(of: client, readJSON(url)) else { return nil }
        return (server["command"] as? String) ?? (server["command"] as? [String])?.first
    }

    /// Lilo's entry among the servers a JSON client keeps under its own key.
    private static func liloServer(of client: Client, _ config: [String: Any]) -> [String: Any]? {
        guard case .json(_, let key, _) = client.config else { return nil }
        return (config[key] as? [String: Any])?["lilo"] as? [String: Any]
    }

    /// Writes through a symlink, so a dotfiles link stays one, and keeps the file's permissions, which may guard keys.
    private static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let mode = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path) }
    }

    private static func readJSON(_ url: URL) -> [String: Any] {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// The table Codex reads; replaced in place, the rest of the file is left byte for byte, comments
    /// included, which a TOML round trip would not keep.
    private static var tomlTable: String { "[mcp_servers.lilo]\ncommand = \"\(helperPath)\"\n" }

    /// From the table header to the next header or the end of the file.
    private static func liloTable(in text: String) -> Range<String.Index>? {
        guard let header = text.range(of: "[mcp_servers.lilo]\n") ?? text.range(of: "[mcp_servers.lilo]") else { return nil }
        let rest = text[header.upperBound...]
        let end = rest.range(of: "\n[").map { text.index(after: $0.lowerBound) } ?? text.endIndex
        return header.lowerBound..<end
    }

    /// The lines that differ, none of the unchanged ones around them: a file's other servers may hold secrets
    /// the page has no business showing. The ends that match are trimmed, an LCS finds the rest.
    static func diff(_ before: String, _ after: String) -> [Preview.Line] {
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        var head = 0
        while head < min(old.count, new.count), old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < min(old.count, new.count) - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let a = Array(old[head..<(old.count - tail)])
        let b = Array(new[head..<(new.count - tail)])
        let fits = a.count * b.count <= 250_000
        var common = Array(repeating: Array(repeating: 0, count: fits ? b.count + 1 : 1), count: fits ? a.count + 1 : 1)
        if fits {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    common[i][j] = a[i] == b[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
                }
            }
        }
        var lines: [Preview.Line] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if fits, i < a.count, j < b.count, a[i] == b[j] {
                i += 1
                j += 1
            } else if i < a.count, !fits || j == b.count || common[i + 1][j] >= common[i][j + 1] {
                lines.append(Preview.Line(number: head + i + 1, removed: true, text: a[i]))
                i += 1
            } else {
                lines.append(Preview.Line(number: head + j + 1, removed: false, text: b[j]))
                j += 1
            }
        }
        return lines
    }

    private static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    /// Off the cooperative pool, with no input: a command still running after `timeout` seconds, like a
    /// login shell whose profile hangs, is killed and gives no output.
    static func run(_ executable: String, _ arguments: [String], timeout: Double) async -> (status: Int32, output: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                guard (try? process.run()) != nil else { return continuation.resume(returning: (-1, nil)) }
                guard exited.wait(timeout: .now() + timeout) == .success else {
                    kill(process.processIdentifier, SIGKILL)
                    return continuation.resume(returning: (-1, nil))
                }
                // A background job of the profile may hold the pipe open: take what is there, never wait for its end.
                let reader = pipe.fileHandleForReading.fileDescriptor
                _ = fcntl(reader, F_SETFL, O_NONBLOCK)
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let count = unsafe read(reader, &buffer, buffer.count)
                continuation.resume(returning: (process.terminationStatus, count > 0 ? String(bytes: buffer[..<count], encoding: .utf8) : ""))
            }
        }
    }
}
