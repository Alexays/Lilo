import Foundation

/// What an agent that takes a conversation over is told about it: the thread's last turns as one block
/// of text. The new agent has no memory of them, and the project's files already hold their work.
enum ConversationHandoff {
    static let maxTurns = 8
    static let maxCharacters = 8_000
    private static let maxToolLines = 8

    private struct Turn {
        var user: String
        /// Typed in Lilo, not replayed from an agent: the agent's echo of it is not a second prompt.
        var local: Bool
        var tools: [(id: String, line: String)] = []
        var reply = ""
        var hasAgentContent: Bool { !reply.isEmpty || !tools.isEmpty }
    }

    /// The turns of `log` (the thread's update entries), newest `maxTurns` and no more than `maxCharacters`
    /// of turn text (the fixed header aside), oldest first; nil when no turn answered yet. Tool calls are one line each.
    static func summary(log: [[String: Any]], from previousAgent: String?, maxTurns: Int = maxTurns, maxCharacters: Int = maxCharacters) -> String? {
        var turns: [Turn] = []
        var lastWasEcho = false
        for entry in log where entry["childSession"] == nil && ConversationHost.parentToolUse(of: entry) == nil {
            let kind = entry["sessionUpdate"] as? String
            defer { lastWasEcho = kind == "user_message_chunk" }
            switch kind {
            case "lilo_user":
                turns.append(Turn(user: entry["text"] as? String ?? "", local: true))
            case "user_message_chunk":
                guard let text = text(of: entry) else { continue }
                if lastWasEcho, !turns.isEmpty {
                    turns[turns.count - 1].user += text
                } else if !(turns.last.map { $0.local && !$0.hasAgentContent } ?? false) {
                    turns.append(Turn(user: text, local: false))
                }
            case "agent_message_chunk":
                guard !turns.isEmpty, let text = text(of: entry) else { continue }
                turns[turns.count - 1].reply += (turns[turns.count - 1].reply.isEmpty ? "" : "\n\n") + text
            case "tool_call":
                guard !turns.isEmpty else { continue }
                let id = entry["toolCallId"] as? String ?? UUID().uuidString
                turns[turns.count - 1].tools.append((id, toolLine(entry)))
            case "tool_call_update":
                guard !turns.isEmpty, let id = entry["toolCallId"] as? String,
                      let index = turns[turns.count - 1].tools.firstIndex(where: { $0.id == id }) else { continue }
                turns[turns.count - 1].tools[index].line = toolLine(entry, previous: turns[turns.count - 1].tools[index].line)
            default:
                break
            }
        }
        // A prompt the agent has not touched yet is the one about to be sent, not history.
        if let last = turns.last, !last.hasAgentContent, last.local { turns.removeLast() }
        turns.removeAll { $0.user.isEmpty && !$0.hasAgentContent }
        guard !turns.isEmpty else { return nil }

        var kept: [String] = []
        var used = 0
        for turn in turns.suffix(maxTurns).reversed() {
            let block = render(turn)
            if !kept.isEmpty, used + block.count > maxCharacters { break }
            kept.append(block)
            used += block.count
        }
        let omitted = turns.count - kept.count
        let who = previousAgent.map { "another agent (\($0))" } ?? "another agent"
        return """
            Lilo is handing this conversation over to you: until now it was with \(who). Below is a summary of its latest turns, not the full history; \
            the files in the working directory hold the current state of the work. Continue from here. The user's new message follows this summary.

            <previous-conversation>
            \(omitted > 0 ? "(\(omitted) earlier turn\(omitted == 1 ? "" : "s") left out)\n\n" : "")\(kept.reversed().joined(separator: "\n\n"))
            </previous-conversation>
            """
    }

    private static func render(_ turn: Turn) -> String {
        var lines = ["User: " + clip(turn.user, 1_200)]
        if !turn.tools.isEmpty {
            lines.append("Tool calls:")
            lines += turn.tools.prefix(maxToolLines).map { "- " + clip($0.line, 140) }
            if turn.tools.count > maxToolLines { lines.append("- and \(turn.tools.count - maxToolLines) more") }
        }
        if !turn.reply.isEmpty { lines.append("Agent: " + clip(turn.reply, 2_000)) }
        return lines.joined(separator: "\n")
    }

    /// The call's title, with `(failed)` once an update says so. An update keeps the title it does not repeat.
    private static func toolLine(_ entry: [String: Any], previous: String? = nil) -> String {
        let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let base = title ?? previous?.replacingOccurrences(of: " (failed)", with: "") ?? entry["kind"] as? String ?? "tool"
        let failed = entry["status"] as? String == "failed" || (entry["status"] == nil && previous?.hasSuffix(" (failed)") == true)
        return failed ? base + " (failed)" : base
    }

    private static func text(of entry: [String: Any]) -> String? {
        let content = entry["content"] as? [String: Any]
        return content?["type"] as? String == "text" ? content?["text"] as? String : nil
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
