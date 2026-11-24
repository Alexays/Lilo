import AppKit

/// The background agent host: the app never takes the keyboard, the mouse or the Dock from the user. It runs as
/// an accessory app, its windows are transparent, clickless and never key, and nothing activates it.
/// `--background` starts Lilo in it (`open -a Lilo --args --background`), as LILO_HEADLESS=1 does on a Debug build
/// (`make agent-app`); closing the last window enters it while Settings > Agents keeps the host running. Opening
/// Lilo again or tapping a consent notification leaves it.
@MainActor
enum Headless {
    static var isOn = requested(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    /// The Settings > Agents switch: closing the last window keeps serving agents in the background.
    static let keepRunningKey = "agentBackgroundHost"
    private static let concealedBehavior: NSWindow.CollectionBehavior = [.transient, .ignoresCycle, .stationary]

    nonisolated static func requested(arguments: [String], environment: [String: String]) -> Bool {
        if arguments.dropFirst().contains("--background") { return true }
        #if DEBUG
        return environment["LILO_HEADLESS"] == "1"
        #else
        return false
        #endif
    }

    static func conceal(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior.formUnion(concealedBehavior)
    }

    /// Only a Dock app changes its policy: the test host keeps its own.
    static func enter(concealing window: NSWindow) {
        isOn = true
        conceal(window)
        if NSApp.activationPolicy() == .regular { NSApp.setActivationPolicy(.accessory) }
        NSApp.deactivate()
    }

    static func leave(revealing windows: [NSWindow]) {
        guard isOn else { return }
        isOn = false
        if NSApp.activationPolicy() == .accessory { NSApp.setActivationPolicy(.regular) }
        for window in windows {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.collectionBehavior.subtract(concealedBehavior)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// WebKit hands a key its page left unhandled back to `sendEvent`, where the menu bar matches it by key code
/// under the user's layout: an agent's key must stop there, or its cmd+a runs Quit on AZERTY.
final class LiloApplication: NSApplication {
    private let holdToQuit = HoldToQuit()

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, AgentInput.sentKeyDowns.contains(event) { return }
        if holdToQuit.handle(event) { return }
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
