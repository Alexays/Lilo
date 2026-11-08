import AppKit

/// WebKit hands a key its page left unhandled back to `sendEvent`, where the menu bar matches it by key code
/// under the user's layout: an agent's key must stop there, or its cmd+a runs Quit on AZERTY.
final class LiloApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, AgentInput.sentKeyDowns.contains(event) { return }
        super.sendEvent(event)
    }
}
