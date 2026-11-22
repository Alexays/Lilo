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
        switch client.config {
        case .claudeCLI:
            guard let claude = await claudeBinary(client, home: home) else { return }
            _ = await run(claude, ["mcp", "remove", "--scope", "user", "lilo"], timeout: 15)
        case .json(let path):
            let url = home.appending(path: path)
            var config = readJSON(url)
            guard var servers = config["mcpServers"] as? [String: Any], servers.removeValue(forKey: "lilo") != nil else { return }
            config["mcpServers"] = servers
            try write(Data(json(config).utf8), to: url)
        case .toml(let path):
            let url = home.appending(path: path)
            guard var text = try? String(contentsOf: url, encoding: .utf8), let range = liloTable(in: text) else { return }
            text.removeSubrange(range)
            try write(Data(text.utf8), to: url)
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

    /// The clients whose configuration names Lilo's server. Reads their files, so off the main thread.
    static func connectedClients(home: URL) -> [Client] {
        Client.all.filter { client in
            let url = home.appending(path: client.config.path)
            if case .toml = client.config {
                return (try? String(contentsOf: url, encoding: .utf8)).flatMap { liloTable(in: $0) } != nil
            }
            return (readJSON(url)["mcpServers"] as? [String: Any])?["lilo"] != nil
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
        switch client.config {
        case .claudeCLI: break
        case .json(let path): try mergeServer(into: home.appending(path: path))
        case .toml(let path): try writeTable(home.appending(path: path))
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
        return ((readJSON(url)["mcpServers"] as? [String: Any])?["lilo"] as? [String: Any])?["command"] as? String
    }

    /// Sets `mcpServers.lilo`, keeping every other key of the file. A file that exists but cannot be read or
    /// is no plain JSON (comments, a trailing comma) is left alone: rewriting it would drop the user's other servers.
    private static func mergeServer(into url: URL) throws {
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw unsafe AgentToolError(String(format: "Lilo could not read %@: add this server to it yourself: %@".localized, url.path, genericConfigJSON))
            }
            config = object
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["lilo"] = ["command": helperPath]
        config["mcpServers"] = servers
        try write(Data(json(config).utf8), to: url)
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

    /// Replaces the `[mcp_servers.lilo]` table in place, or appends it: the rest of the file is left
    /// byte for byte, comments included, which a TOML round trip would not keep.
    private static func writeTable(_ url: URL) throws {
        let table = "[mcp_servers.lilo]\ncommand = \"\(helperPath)\"\n"
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                throw unsafe AgentToolError(String(format: "Lilo could not read %@: add this server to it yourself: %@".localized, url.path, table))
            }
            text = existing
        }
        if let range = liloTable(in: text) {
            text.replaceSubrange(range, with: table)
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + table
        }
        try write(Data(text.utf8), to: url)
    }

    /// From the table header to the next header or the end of the file.
    private static func liloTable(in text: String) -> Range<String.Index>? {
        guard let header = text.range(of: "[mcp_servers.lilo]\n") ?? text.range(of: "[mcp_servers.lilo]") else { return nil }
        let rest = text[header.upperBound...]
        let end = rest.range(of: "\n[").map { text.index(after: $0.lowerBound) } ?? text.endIndex
        return header.lowerBound..<end
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
