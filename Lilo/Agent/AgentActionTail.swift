import Foundation

/// The latest calls in the action log, for Settings: read only when the page asks, never more than
/// `maxBytes` of a file, and only what the writer already redacted (the tool, the host, whether it worked).
enum AgentActionTail {
    struct Call: Equatable {
        /// ISO 8601 as the writer wrote it.
        let time: String
        let tool: String
        let host: String?
        let ok: Bool
        let code: String?
    }

    struct Client: Equatable {
        let name: String
        let calls: [Call]
    }

    static let maxBytes = 64 << 10
    private static let maxClients = 12
    private static let maxField = 120

    /// Each client's latest `limit` calls, newest first, the most recently active client first. `names` maps a log file
    /// (`AgentActionLog.clientFile`) to how people know its client; a file it lacks shows under its own name.
    static func clients(in directory: URL, names known: [String: String], limit: Int = 8) -> [Client] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        let sources = files.compactMap { file -> (name: String, modified: Date)? in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jsonl", name.hasPrefix("client-"), !name.contains("."),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (name, modified)
        }.sorted { $0.modified > $1.modified }.prefix(maxClients)
        return sources.compactMap { source in
            let calls = recent(source.name, in: directory, limit: limit)
            return calls.isEmpty ? nil : Client(name: known[source.name] ?? String(source.name.dropFirst("client-".count)), calls: calls)
        }
    }

    /// The last `limit` calls of one log, newest first: the live file, then the rotated one when the live one is short.
    static func recent(_ name: String, in directory: URL, limit: Int, maxBytes: Int = maxBytes) -> [Call] {
        var calls: [Call] = []
        for suffix in [".jsonl", ".1.jsonl"] where calls.count < limit {
            let older = tail(directory.appending(path: name + suffix), maxBytes: maxBytes).compactMap(parse)
            calls = older.suffix(limit - calls.count) + calls
        }
        return calls.reversed()
    }

    /// The whole lines in the last `maxBytes` of a file, oldest first. A line the cut or a write in flight split
    /// is dropped when it fails to parse.
    private static func tail(_ file: URL, maxBytes: Int) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else { return [] }
        defer { try? handle.close() }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: maxBytes) else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map { Data($0) }
    }

    private static func parse(_ line: Data) -> Call? {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let time = entry["ts"] as? String, let tool = entry["tool"] as? String else { return nil }
        return Call(
            time: String(time.prefix(maxField)), tool: String(tool.prefix(maxField)),
            host: (entry["host"] as? String).map { String($0.prefix(maxField)) },
            ok: entry["ok"] as? Bool ?? true, code: (entry["code"] as? String).map { String($0.prefix(maxField)) }
        )
    }
}
