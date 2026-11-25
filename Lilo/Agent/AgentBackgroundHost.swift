import AppKit

/// Settings > Agents > "Stay open for agents": closing the last window orders it out instead of quitting,
/// so agents keep their socket and tabs. Ordered out, the window is occluded: WebKit throttles the user's
/// pages and the hidden-window lifecycle freezes them, while agent tabs, which ignore occlusion, keep
/// working. Lilo leaves the Dock for a menu bar item, which exists only while the host runs.
@MainActor
final class AgentBackgroundHost: NSObject {
    static let settingKey = "agentBackgroundHost"

    private var item: NSStatusItem?
    private weak var window: NSWindow?
    private(set) var isOn = false

    /// Closing `window` hides it: media in the user's own tabs stops, as it would on a real close.
    func enter(hiding window: NSWindow, context: BrowserContext) {
        window.orderOut(nil)
        self.window = window
        for engine in context.browserState.enginesAcrossSpaces.values where !engine.isAgentControlled {
            engine.wkWebView.pauseAllMediaPlayback()
        }
        guard !isOn else { return }
        isOn = true
        // A test run keeps the Dock, the menu bar and the focus as they are.
        guard !ProcessInfo.isRunningUnderXCTest else { return }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Open for agents".localized)
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Open for agents".localized))
        let show = NSMenuItem(title: "Show Lilo".localized, action: #selector(leave), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lilo".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
        self.item = item
    }

    /// Back in the Dock with the window in front. Anything that shows the window again leaves too.
    @objc func leave() {
        guard isOn else { return }
        isOn = false
        if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
