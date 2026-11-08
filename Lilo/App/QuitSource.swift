import AppKit
import OSLog

/// Says in the log where a request to quit came from, since a quit leaves no crash report to explain it.
/// Like a performance recording, this holds no URL, title or typed text: the key pressed and a tool's
/// arguments never reach it, and the log stays on this Mac.
@MainActor
enum QuitSource {
    private static let logger = Logger(liloCategory: "quit")
    private static var lastAgentTool: (name: String, at: Date)?

    static func noteAgentTool(_ name: String) {
        lastAgentTool = (name, Date())
    }

    static func log() {
        let appleEvent = NSAppleEventManager.shared().currentAppleEvent
        let senderPID = appleEvent?.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let source = describe(
            isAppleEvent: appleEvent != nil,
            sender: senderPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
            eventType: NSApp.currentEvent?.type,
            // By character, not key code: the Q key sits elsewhere on AZERTY.
            isQuitKey: NSApp.currentEvent.map { $0.type == .keyDown && $0.charactersIgnoringModifiers?.lowercased() == "q" } ?? false
        )
        let tool = describe(tool: lastAgentTool?.name, secondsAgo: lastAgentTool.map { Date().timeIntervalSince($0.at) },
                            known: Set(AgentTools.definitions.compactMap { $0["name"] as? String }))
        logger.notice("Quit requested by \(source, privacy: .public); \(tool, privacy: .public)")
    }

    static func describe(isAppleEvent: Bool, sender: String?, eventType: NSEvent.EventType?, isQuitKey: Bool) -> String {
        if isAppleEvent { return "an Apple Event from \(sender ?? "an unknown process")" }
        switch eventType {
        case .keyDown: return isQuitKey ? "the Q key" : "another key"
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: return "a click"
        default: return "Lilo itself"
        }
    }

    /// A client names the tool it calls, so only a name Lilo offers reaches the log.
    static func describe(tool: String?, secondsAgo: TimeInterval?, known: Set<String>) -> String {
        guard let tool, let secondsAgo, known.contains(tool) else { return "no agent tool ran" }
        return "agent tool \(tool) ran \(Int(secondsAgo)) s before"
    }
}
