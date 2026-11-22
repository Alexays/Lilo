import AppKit
import Foundation

/// Registers `lilo-mcp` with the agents people run, each in its own configuration file, as `HarnessDefinition` says.
enum AgentClientConfig {
    typealias Client = HarnessDefinition

    /// The MCP server the agents launch: a pipe to Lilo's agent socket, shipped next to Lilo's own binary.
    static var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/lilo-mcp").path
    }

    static var genericConfigJSON: String { newJSON(key: "mcpServers", entry: .command) }

    /// A whole file holding only Lilo's entry, laid out as people write JSON.
    private static func newJSON(key: String, entry: HarnessDefinition.Entry) -> String {
        "{\n  \(jsonString(key)): {\n    \(liloMember(entry, colon: ": ", newline: "\n", indent: "  ", at: "    "))\n  }\n}"
    }

    private static func jsonString(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? "\"\""
    }

    /// `"lilo": {...}` with the file's own colon spacing: on one line when `at` is nil, else one field per line
    /// below `at`, the indentation of its first line.
    private static func liloMember(_ entry: HarnessDefinition.Entry, colon: String, newline: String, indent: String, at: String?) -> String {
        let fields = entry.fields(jsonString(helperPath)).map { "\(jsonString($0.key))\(colon)\($0.value)" }
        guard let at else { return "\"lilo\"\(colon){\(fields.joined(separator: ", "))}" }
        let body = fields.map { newline + at + indent + $0 }.joined(separator: ",")
        return "\"lilo\"\(colon){\(body)\(newline)\(at)}"
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
    static func manualSnippet(_ client: Client) -> String {
        switch client.config {
        case .claudeCLI: "claude mcp add --scope user lilo -- \(helperPath)"
        case .json(_, let key, let entry): newJSON(key: key, entry: entry)
        case .toml: (String(bytes: tomlTable([10]) + [10], encoding: .utf8) ?? "")
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
                return (try? Data(contentsOf: url)).flatMap { liloTable(Array($0)) } != nil
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
    /// nothing to change. The one place the new content is made, so the preview is what gets written. Only
    /// Lilo's own entry changes: every other byte of the file stays as it was.
    private static func edit(_ client: Client, home: URL, remove: Bool) throws -> (url: URL, before: String, after: String)? {
        let url: URL
        switch client.config {
        case .claudeCLI: return nil
        case .json(let path, _, _), .toml(let path): url = home.appending(path: path)
        }
        var bytes: [UInt8] = []
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), String(data: data, encoding: .utf8) != nil else {
                if remove { return nil }
                throw unsafe AgentToolError(String(format: "Lilo could not read %@: add this server to it yourself: %@".localized, url.path, manualSnippet(client)))
            }
            bytes = Array(data)
        }
        let edited: [UInt8]?
        if case .json(_, let key, let entry) = client.config {
            do {
                edited = try editJSON(bytes, key: key, entry: entry, remove: remove)
            } catch {
                if remove { return nil }
                throw unsafe AgentToolError(String(format: "Lilo could not read %@: add this server to it yourself: %@".localized, url.path, manualSnippet(client)))
            }
        } else {
            edited = editTOML(bytes, remove: remove)
        }
        guard let edited, edited != bytes else { return nil }
        return (url, (String(bytes: bytes, encoding: .utf8) ?? ""), (String(bytes: edited, encoding: .utf8) ?? ""))
    }

    /// The `command` a client has for Lilo's server in a file Lilo writes, nil for Claude Code, whose store
    /// only its CLI edits.
    private static func serverCommand(of client: Client, home: URL) -> String? {
        let url = home.appending(path: client.config.path)
        if case .claudeCLI = client.config { return nil }
        if case .toml = client.config {
            guard let data = try? Data(contentsOf: url), let range = liloTable(Array(data)) else { return nil }
            return (String(bytes: Array(data)[range], encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("command") })?
                .split(separator: "\"").dropFirst().first.map(String.init)
        }
        guard let server = liloServer(of: client, readJSON(url)) else { return nil }
        return (server["command"] as? String) ?? (server["command"] as? [String])?.first
    }

    /// Lilo's entry among the servers a JSON client keeps under its own key.
    private static func liloServer(of client: Client, _ config: [String: Any]) -> [String: Any]? {
        var key = "mcpServers"
        switch client.config {
        case .json(_, let own, _): key = own
        case .claudeCLI: break
        case .toml: return nil
        }
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

    /// The table Codex reads, with the file's own line ending.
    private static func tomlTable(_ newline: [UInt8]) -> [UInt8] {
        Array("[mcp_servers.lilo]".utf8) + newline + Array("command = \"\(helperPath)\"".utf8)
    }

    /// Adds, replaces or removes Lilo's table and nothing else: Connect then Remove gives the file back byte for byte,
    /// comments included, which a TOML round trip would not keep.
    private static func editTOML(_ text: [UInt8], remove: Bool) -> [UInt8]? {
        let newline = lineEnding(text)
        guard let range = liloTable(text) else {
            if remove { return nil }
            if text.isEmpty { return tomlTable(newline) + newline }
            // After a blank line; a file with no final newline gets none, so Remove can give it back as it was.
            return text.last == UInt8(ascii: "\n") ? text + newline + tomlTable(newline) + newline : text + newline + newline + tomlTable(newline)
        }
        let endsLine = text[range].last == UInt8(ascii: "\n")
        if !remove {
            return Array(text[..<range.lowerBound]) + tomlTable(newline) + (endsLine ? newline : []) + text[range.upperBound...]
        }
        var start = range.lowerBound
        // At the end of the file, the blank line Connect put before the table goes too.
        if range.upperBound == text.count {
            for _ in 0..<(endsLine ? 1 : 2) where start >= newline.count && text[(start - newline.count)..<start].elementsEqual(newline) { start -= newline.count }
        }
        return Array(text[..<start] + text[range.upperBound...])
    }

    private static func lineEnding(_ text: [UInt8]) -> [UInt8] {
        text.firstIndex(of: UInt8(ascii: "\n")).map { $0 > 0 && text[$0 - 1] == UInt8(ascii: "\r") } == true ? [13, 10] : [10]
    }

    /// Lilo's table and its sub-tables, from the header at the start of a line through the line ending of its last
    /// line that is not blank; the blank lines before the next table are not its own.
    private static func liloTable(_ text: [UInt8]) -> Range<Int>? {
        let header = Array("[mcp_servers.lilo]".utf8)
        guard let start = text.indices.first(where: { index in
            (index == 0 || text[index - 1] == UInt8(ascii: "\n")) && text[index...].starts(with: header)
        }) else { return nil }
        var end = text.count
        var line = start
        while let newline = text[line...].firstIndex(of: UInt8(ascii: "\n")) {
            line = newline + 1
            if line < text.count, text[line] == UInt8(ascii: "["), !text[line...].starts(with: Array("[mcp_servers.lilo.".utf8)) {
                end = line
                break
            }
        }
        while end > start, [UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(text[end - 1]) { end -= 1 }
        if end < text.count, text[end] == UInt8(ascii: "\r") { end += 1 }
        if end < text.count, text[end] == UInt8(ascii: "\n") { end += 1 }
        return start..<end
    }

    /// Adds, replaces or removes `mcpServers.lilo` in the text itself, with the spacing and indentation of its
    /// neighbours, so the rest of the file (key order, spacing, escapes) is left byte for byte. Throws on a file
    /// that is no strict JSON object, or whose `mcpServers` is no object: rewriting it could lose the user's servers.
    private static func editJSON(_ text: [UInt8], key: String, entry: HarnessDefinition.Entry, remove: Bool) throws -> [UInt8]? {
        let newline = lineEnding(text)
        guard text.contains(where: { !jsonSpace($0) }) else {
            return remove ? nil : Array(newJSON(key: key, entry: entry).utf8) + newline
        }
        guard (try? JSONSerialization.jsonObject(with: Data(text))) is [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let root = jsonObject(text, open: skipJSONSpace(text, 0))
        // `"key": ` as the file writes it, from the first member that shows it.
        let colon = root.members.first.map { (String(bytes: text[$0.keyEnd..<$0.valueStart], encoding: .utf8) ?? "") } ?? ": "
        let indent = indentUnit(text)
        let nl = String(bytes: newline, encoding: .utf8) ?? "\n"
        let lilo = { (at: String?) in liloMember(entry, colon: colon, newline: nl, indent: indent, at: at) }
        guard let servers = root.members.first(where: { $0.key == key }) else {
            if remove { return nil }
            return insert(text, into: root, newline: newline, indent: indent) { at in
                guard let at else { return "\(jsonString(key))\(colon){\(lilo(nil))}" }
                return "\(jsonString(key))\(colon){\(nl)\(at)\(indent)\(lilo(at + indent))\(nl)\(at)}"
            }
        }
        guard text[servers.valueStart] == UInt8(ascii: "{") else { throw CocoaError(.fileReadCorruptFile) }
        let object = jsonObject(text, open: servers.valueStart)
        guard let index = object.members.firstIndex(where: { $0.key == "lilo" }) else {
            return remove ? nil : insert(text, into: object, newline: newline, indent: indent, member: lilo)
        }
        let member = object.members[index]
        if remove {
            let range = object.members.count == 1 ? object.open + 1..<object.close
                : index > 0 ? object.members[index - 1].valueEnd..<member.valueEnd : member.start..<object.members[index + 1].start
            return Array(text[..<range.lowerBound] + text[range.upperBound...])
        }
        let entry = Array(lilo(lineIndent(text, member.start)).utf8)
        return Array(text[..<member.start]) + entry + text[member.valueEnd...]
    }

    private struct JSONMember {
        let key: String
        let start: Int
        let keyEnd: Int
        let valueStart: Int
        let valueEnd: Int
    }

    /// The members of the object whose `{` is at `open`, in a text already known to be strict JSON.
    private static func jsonObject(_ text: [UInt8], open: Int) -> (open: Int, close: Int, members: [JSONMember]) {
        var members: [JSONMember] = []
        var index = skipJSONSpace(text, open + 1)
        while index < text.count, text[index] != UInt8(ascii: "}") {
            let keyEnd = jsonValueEnd(text, index)
            let key = (try? JSONSerialization.jsonObject(with: Data(text[index..<keyEnd]), options: .fragmentsAllowed)) as? String ?? ""
            let valueStart = skipJSONSpace(text, skipJSONSpace(text, keyEnd) + 1)
            let valueEnd = jsonValueEnd(text, valueStart)
            members.append(JSONMember(key: key, start: index, keyEnd: keyEnd, valueStart: valueStart, valueEnd: valueEnd))
            index = skipJSONSpace(text, valueEnd)
            if index < text.count, text[index] == UInt8(ascii: ",") { index = skipJSONSpace(text, index + 1) }
        }
        return (open, index, members)
    }

    /// Adds `member` as the object's last member: on its own line at its siblings' indentation, or inline beside
    /// them when they share a line. `member` gets the indentation of its first line, nil for an inline one.
    private static func insert(
        _ text: [UInt8], into object: (open: Int, close: Int, members: [JSONMember]), newline: [UInt8], indent: String,
        member: (String?) -> String
    ) -> [UInt8] {
        guard let last = object.members.last else {
            let at = (lineIndent(text, object.open, leading: true) ?? "") + indent
            let body = newline + Array((at + member(at)).utf8) + newline + Array((lineIndent(text, object.open, leading: true) ?? "").utf8)
            return Array(text[...object.open]) + body + text[object.close...]
        }
        let at = lineIndent(text, last.start)
        let added = at.map { newline + Array(($0 + member($0)).utf8) } ?? Array(" \(member(nil))".utf8)
        return Array(text[..<last.valueEnd]) + Array(",".utf8) + added + text[last.valueEnd...]
    }

    /// The spaces or tabs before `index` on its line: all of them when `leading` (the line's own indentation),
    /// otherwise only when nothing else precedes it there; nil for a member that shares its line.
    private static func lineIndent(_ text: [UInt8], _ index: Int, leading: Bool = false) -> String? {
        var start = index
        while start > 0, text[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        let prefix = text[start..<index]
        let spaces = prefix.prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
        guard leading || spaces.count == prefix.count else { return nil }
        return (String(bytes: spaces, encoding: .utf8) ?? "")
    }

    /// One level of the file's indentation: the first indented line's, or two spaces.
    private static func indentUnit(_ text: [UInt8]) -> String {
        var index = 0
        while let newline = text[index...].firstIndex(of: UInt8(ascii: "\n")) {
            index = newline + 1
            let spaces = text[index...].prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
            if !spaces.isEmpty { return (String(bytes: spaces, encoding: .utf8) ?? "") }
        }
        return "  "
    }

    private static func jsonSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

    private static func skipJSONSpace(_ text: [UInt8], _ index: Int) -> Int {
        text[index...].firstIndex { !jsonSpace($0) } ?? text.count
    }

    /// One past the end of the value (string, number, literal, object or array) that starts at `start`.
    private static func jsonValueEnd(_ text: [UInt8], _ start: Int) -> Int {
        var index = start
        var depth = 0
        var inString = false
        while index < text.count {
            let byte = text[index]
            index += 1
            if inString {
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                    if depth == 0 { return index }
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return index }
            } else if depth == 0, index < text.count, jsonSpace(text[index]) || ",}]".utf8.contains(text[index]) {
                return index
            }
        }
        return index
    }

    /// The lines that differ, none of the unchanged ones around them: a file's other servers may hold secrets
    /// the page has no business showing. The ends that match are trimmed, an LCS finds the rest.
    static func diff(_ before: String, _ after: String) -> [Preview.Line] {
        // A CRLF file's lines keep no "\r" on the page.
        let split = { (text: String) in text.isEmpty ? [] : text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } }
        let old = split(before)
        let new = split(after)
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
