import AppKit

/// LILO_HEADLESS=1 on a Debug build (`make agent-app` sets it): the app never takes the keyboard, the mouse or the
/// Dock from the user. It runs as an accessory app, its windows are transparent, clickless and never key, and
/// nothing activates it. A Release build never reads the variable.
enum Headless {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.environment["LILO_HEADLESS"] == "1"
    #else
    static let isOn = false
    #endif
}

/// WebKit hands a key its page left unhandled back to `sendEvent`, where the menu bar matches it by key code
/// under the user's layout: an agent's key must stop there, or its cmd+a runs Quit on AZERTY.
final class LiloApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, AgentInput.sentKeyDowns.contains(event) { return }
        super.sendEvent(event)
    }

    override func activate() {
        if !Headless.isOn { super.activate() }
    }

    @available(macOS, deprecated: 14.0)
    override func activate(ignoringOtherApps flag: Bool) {
        if !Headless.isOn { super.activate(ignoringOtherApps: flag) }
    }
}
