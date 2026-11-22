import Foundation

/// One JSONL line per tool call an agent made, in `Agents/Actions` of the app's support folder: the record
/// a replay, a retry or a skill is built from later. Each source (a conversation, or an MCP client) has its
/// own file, which rotates at `maxBytes`. What the user typed, scripts, bodies, cookies and paths never
/// reach it: see `redact`.
@MainActor
final class AgentActionLog {
    static let settingKey = "agentActionLog"
    static let defaultMaxBytes = 1 << 20

    /// Arguments kept as given when they are strings: they name an action, never carry the user's data.
    private static let plainStrings: Set<String> = [
        "action", "scroll_direction", "method", "responseType", "credentials", "ref", "ref_id", "state", "modifiers"
    ]
    /// Never kept, even a number: `form_input` can set a digit-only one-time code.
    private static let alwaysMasked: Set<String> = ["value", "text", "cookie", "body", "headers", "params"]

    private let writer: Writer

    init(directory: URL, maxBytes: Int = defaultMaxBytes) {
        writer = Writer(directory: directory, maxBytes: maxBytes)
    }

    /// The file a session's calls go to: its conversation's, else its client's.
    static func name(for session: AgentSession) -> String {
        if let tab = session.conversationTabId { return "conversation-\(tab.uuidString)" }
        let client = session.clientName.lowercased().unicodeScalars.map { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) ? Character($0) : "-" }
        return "client-" + String(String(client).prefix(40))
    }

    /// The arguments as logged: ids, actions and numbers as given, a URL as its host, every other string as its length.
    static func redact(_ arguments: [String: Any]) -> [String: Any] {
        var kept: [String: Any] = [:]
        for (key, value) in arguments {
            if key == "url", let url = value as? String {
                kept[key] = URL(string: url)?.host ?? "[no host]"
            } else if alwaysMasked.contains(key) {
                kept[key] = mask(value)
            } else if let string = value as? String {
                kept[key] = plainStrings.contains(key) ? string : mask(string)
            } else if value is NSNumber {
                kept[key] = value
            } else if let numbers = value as? [NSNumber] {
                kept[key] = numbers
            } else {
                kept[key] = mask(value)
            }
        }
        return kept
    }

    private static func mask(_ value: Any) -> [String: Any] {
        if let string = value as? String { return ["chars": string.count] }
        if let items = value as? [Any] { return ["items": items.count] }
        if let object = value as? [String: Any] { return ["keys": object.count] }
        return ["redacted": true]
    }

    /// Appends the call as one line, off the main thread.
    func record(
        tool: String, arguments: [String: Any], session: AgentSession, host: String?,
        ok: Bool, code: String?, possibleCommit: Bool, startedAt: Date
    ) {
        var line: [String: Any] = [
            "ts": startedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "tool": tool, "args": Self.redact(arguments), "ok": ok,
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
        ]
        if let code { line["code"] = code }
        if possibleCommit { line["possibleCommit"] = true }
        if let tab = (arguments["tabId"] as? NSNumber)?.intValue { line["tabId"] = tab }
        if let host { line["host"] = host }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        writer.append(data, to: Self.name(for: session))
    }

    /// Waits for the lines queued so far, for a test and a quit.
    func flush() { writer.flush() }

    /// Deletes a source's log, as the conversation it belongs to goes.
    nonisolated static func remove(_ name: String, in directory: URL) {
        for suffix in [".jsonl", ".1.jsonl"] { try? FileManager.default.removeItem(at: directory.appending(path: name + suffix)) }
    }

    /// Opens the file for each line and closes it: nothing is held while the agent is idle.
    private final class Writer: @unchecked Sendable {
        private let directory: URL
        private let maxBytes: Int
        private let queue = DispatchQueue(label: "lilo.agent.actionlog", qos: .utility)
        /// Sizes of the files written this run, so a line costs no `stat`. Touched on `queue` only.
        private var sizes: [String: Int] = [:]

        init(directory: URL, maxBytes: Int) {
            self.directory = directory
            self.maxBytes = maxBytes
        }

        func append(_ data: Data, to name: String) {
            queue.async { [self] in
                let fileManager = FileManager.default
                let file = directory.appending(path: name + ".jsonl")
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var size = sizes[name] ?? ((try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
                if size > 0, size + data.count > maxBytes {
                    let old = directory.appending(path: name + ".1.jsonl")
                    try? fileManager.removeItem(at: old)
                    try? fileManager.moveItem(at: file, to: old)
                    size = 0
                }
                if !fileManager.fileExists(atPath: file.path) {
                    fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                guard let handle = try? FileHandle(forWritingTo: file) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                do {
                    try handle.write(contentsOf: data)
                    sizes[name] = size + data.count
                } catch {
                    sizes[name] = nil
                }
            }
        }

        func flush() { queue.sync {} }
    }
}

extension AgentControl {
    /// The host of the page in the tab the call named, without opening or waking anything.
    func actionHost(_ arguments: [String: Any], session: AgentSession) -> String? {
        guard let number = (arguments["tabId"] as? NSNumber)?.intValue, let (space, _) = try? agentSpace(for: session) else { return nil }
        let tab = session.folders.values.lazy.flatMap { self.tabs(inFolder: $0, spaceId: space.id) }.first { self.tabNumbers[$0.id] == number }
            ?? isolatedTabs(of: session).first { tabNumbers[$0.id] == number }
        return tab?.url?.host
    }
}
