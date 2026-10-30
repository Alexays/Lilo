import AppKit
import Foundation

/// Registers `lilo-mcp` with the agents people run, each in its own configuration file.
enum AgentClientConfig {
    enum Client: String, CaseIterable {
        case claudeCode, claudeDesktop, codex, cursor

        /// The client behind the name an agent gives when it connects ("claude-ai" is Claude Desktop).
        init?(clientName: String) {
            switch clientName.lowercased() {
            case "claude-code": self = .claudeCode
            case "claude-ai", _ where clientName.lowercased().hasPrefix("local-agent-mode-"): self = .claudeDesktop
            case "codex", "codex-mcp-client": self = .codex
            case "cursor", "cursor-vscode": self = .cursor
            default: return nil
            }
        }
    }

    /// The MCP server the agents launch: a pipe to Lilo's agent socket, shipped next to Lilo's own binary.
    static var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/lilo-mcp").path
    }

    static var genericConfigJSON: String {
        json(["mcpServers": ["lilo": ["command": helperPath]]])
    }

    /// Writes the client's configuration and says what it did, for the settings page.
    static func connect(_ client: Client, home: URL) async throws -> String {
        switch client {
        case .claudeCode:
            // Its installers' places first: Lilo, started from the Finder, has no terminal PATH, and a login
            // shell leaves out what .zshrc adds (~/.local/bin included).
            let installed = binary("claude", home: home, extra: [home.appending(path: ".claude/local/claude").path])
            let found = installed == nil ? await run("/bin/zsh", ["-lc", "command -v claude"], timeout: 5).output : installed
            guard let claude = found?.trimmingCharacters(in: .whitespacesAndNewlines), !claude.isEmpty else {
                throw AgentToolError(String(format: "Claude Code is not installed. Once it is, run: %@".localized, "claude mcp add --scope user lilo -- \(helperPath)"))
            }
            // `add` refuses a name already taken, by this Lilo or one that moved.
            _ = await run(claude, ["mcp", "remove", "--scope", "user", "lilo"], timeout: 15)
            let added = await run(claude, ["mcp", "add", "--scope", "user", "lilo", "--", helperPath], timeout: 15)
            guard added.status == 0 else { throw AgentToolError(String(format: "Claude Code refused the server: %@".localized, added.output ?? "")) }
            return "Added Lilo to Claude Code".localized
        case .claudeDesktop:
            try mergeServer(into: claudeDesktopConfig(home: home))
            return "Added Lilo to Claude Desktop: quit and reopen Claude to load it".localized
        case .cursor:
            try mergeServer(into: cursorConfig(home: home))
            return "Added Lilo to Cursor".localized
        case .codex:
            try writeCodexTable(codexConfig(home: home))
            return "Added Lilo to Codex".localized
        }
    }

    /// Points configurations at this Lilo again when it moved since they were written; returns the
    /// clients it fixed. Claude Code keeps its own store, which only its CLI edits.
    @discardableResult
    static func repairMovedConfigs(home: URL) -> [Client] {
        var repaired: [Client] = []
        for (client, url) in [(Client.claudeDesktop, claudeDesktopConfig(home: home)), (.cursor, cursorConfig(home: home))] {
            guard let command = ((readJSON(url)["mcpServers"] as? [String: Any])?["lilo"] as? [String: Any])?["command"] as? String,
                  command != helperPath, !FileManager.default.fileExists(atPath: command) else { continue }
            if (try? mergeServer(into: url)) != nil { repaired.append(client) }
        }
        let codex = codexConfig(home: home)
        if let text = try? String(contentsOf: codex, encoding: .utf8), let range = codexTable(in: text),
           let command = text[range].split(separator: "\n").first(where: { $0.hasPrefix("command") })?
            .split(separator: "\"").dropFirst().first.map(String.init),
           command != helperPath, !FileManager.default.fileExists(atPath: command),
           (try? writeCodexTable(codex)) != nil {
            repaired.append(.codex)
        }
        return repaired
    }

    /// The clients whose configuration names Lilo's server. Reads their files, so off the main thread.
    static func connectedClients(home: URL) -> [Client] {
        Client.allCases.filter { client in
            let config: URL
            switch client {
            case .codex:
                let text = try? String(contentsOf: codexConfig(home: home), encoding: .utf8)
                return text.flatMap(codexTable(in:)) != nil
            // `claude mcp add --scope user` keeps its servers in ~/.claude.json.
            case .claudeCode: config = home.appending(path: ".claude.json")
            case .claudeDesktop: config = claudeDesktopConfig(home: home)
            case .cursor: config = cursorConfig(home: home)
            }
            return (readJSON(config)["mcpServers"] as? [String: Any])?["lilo"] != nil
        }
    }

    /// The app whose icon stands for the client: its own, or Terminal for a command-line tool. nil when
    /// the client does not look installed; a tool installed elsewhere still left its folder in the home.
    static func iconApp(of client: Client, home: URL) -> URL? {
        let workspace = NSWorkspace.shared
        let terminal = { workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") }
        switch client {
        case .claudeDesktop: return workspace.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
        case .cursor: return workspace.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
        case .claudeCode:
            let found = binary("claude", home: home, extra: [home.appending(path: ".claude/local/claude").path]) != nil
                || FileManager.default.fileExists(atPath: home.appending(path: ".claude").path)
            return found ? terminal() : nil
        case .codex:
            if let app = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") { return app }
            let found = binary("codex", home: home, extra: []) != nil || FileManager.default.fileExists(atPath: home.appending(path: ".codex").path)
            return found ? terminal() : nil
        }
    }

    private static func binary(_ name: String, home: URL, extra: [String]) -> String? {
        ([home.appending(path: ".local/bin/\(name)").path] + extra + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"])
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func claudeDesktopConfig(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    }

    private static func cursorConfig(home: URL) -> URL { home.appending(path: ".cursor/mcp.json") }

    private static func codexConfig(home: URL) -> URL { home.appending(path: ".codex/config.toml") }

    /// Sets `mcpServers.lilo`, keeping every other key of the file. A file that exists but is no plain
    /// JSON (comments, a trailing comma) is left alone: rewriting it would drop the user's other servers.
    private static func mergeServer(into url: URL) throws {
        if let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil {
            throw AgentToolError(String(format: "Lilo could not read %@: add this server to it yourself: %@".localized, url.path, genericConfigJSON))
        }
        var config = readJSON(url)
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
    private static func writeCodexTable(_ url: URL) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let table = "[mcp_servers.lilo]\ncommand = \"\(helperPath)\"\n"
        if let range = codexTable(in: text) {
            text.replaceSubrange(range, with: table)
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + table
        }
        try write(Data(text.utf8), to: url)
    }

    /// From the table header to the next header or the end of the file.
    private static func codexTable(in text: String) -> Range<String.Index>? {
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
                let count = read(reader, &buffer, buffer.count)
                continuation.resume(returning: (process.terminationStatus, count > 0 ? String(bytes: buffer[..<count], encoding: .utf8) : ""))
            }
        }
    }
}
