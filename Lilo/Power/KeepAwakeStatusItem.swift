import AppKit

/// The menu bar item shown while Lilo keeps the Mac awake, in or out of focus: its menu names what
/// holds the Mac and gives sleep back. Nothing exists while the Mac is free to sleep.
@MainActor
final class KeepAwakeStatusItem: NSObject, NSMenuDelegate {
    private weak var context: BrowserContext?
    private var item: NSStatusItem?
    private var state = PowerKeeper.State()
    private var pendingRemoval: DispatchWorkItem?

    init(context: BrowserContext) {
        self.context = context
    }

    private var title: String {
        (state.holdsLidClosed ? "Awake, lid closed" : "Staying awake").localized
    }

    func update(_ state: PowerKeeper.State) {
        self.state = state
        guard state.keepsAwake else {
            // Holding drops for a moment between two commands: the item stays through such gaps
            // instead of leaving and coming back, shifting the menu bar each time.
            guard item != nil, pendingRemoval == nil else { return }
            let removal = DispatchWorkItem { [weak self] in
                guard let self else { return }
                pendingRemoval = nil
                if let item { NSStatusBar.system.removeStatusItem(item) }
                item = nil
            }
            pendingRemoval = removal
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: removal)
            return
        }
        pendingRemoval?.cancel()
        pendingRemoval = nil
        let item = item ?? makeItem()
        self.item = item
        let image = state.holdsLidClosed ? Self.lidClosedIcon : Self.icon
        if item.button?.image !== image { item.button?.image = image }
        item.button?.setAccessibilityLabel(title)
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        return item
    }

    /// Built on each open, so its durations are read then rather than ticked while it is closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: title))
        guard let context else { return }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 2
        let host = context.terminalHost
        let holding = host.liveTabIds
            .filter(state.working.contains)
            .compactMap { id in host.view(for: id).map { (id, $0.session.status) } }
            .sorted { $0.1.awaitingInputSince != nil && $1.1.awaitingInputSince == nil }
        for (id, status) in holding {
            guard let spaceId = context.browserState.durableTab(for: id)?.spaceId,
                  let space = context.spaceManager?.space(with: spaceId), !space.isPrivate else { continue }
            let since = status.awaitingInputSince ?? status.commandStarted
            let duration = since.flatMap { formatter.string(from: max(60, Date().timeIntervalSince($0))) }
            let activity = switch (status.awaitingInputSince, duration) {
            case (.some, let duration?): unsafe String(format: "Waiting for %@".localized, duration)
            case (nil, let duration?): unsafe String(format: "Working for %@".localized, duration)
            case (_, nil): "Working".localized
            }
            let row = NSMenuItem(title: MainWindowController.terminalTitle(for: status), action: #selector(reveal(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = id
            row.subtitle = "\(activity) · \(space.name)"
            row.image = NSImage(systemSymbolName: status.awaitingInputSince == nil ? "terminal" : "hourglass", accessibilityDescription: nil)
            menu.addItem(row)
        }
        let agents = Set(context.agentControl.sessions.filter { state.working.contains($0.id) }.map { AgentControl.displayName($0.clientName) })
        for agent in agents.sorted() {
            let row = NSMenuItem(title: agent, action: #selector(showAgents), keyEquivalent: "")
            row.target = self
            row.subtitle = "Working in the Agents space".localized
            row.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let sleep = NSMenuItem(title: "Let sleep".localized, action: #selector(letSleep), keyEquivalent: "")
        sleep.target = self
        sleep.subtitle = "Until the next command starts".localized
        sleep.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        menu.addItem(sleep)
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let window = context?.windows.window(forTab: id) else { return }
        NSApp.activate()
        window.revealTerminal(id)
    }

    @objc private func showAgents() {
        guard let context, let window = context.windows.activeWindow ?? context.windows.windows.first else { return }
        let ids = context.settingsStore?.agentsSpaceIds ?? []
        guard let id = ids.first(where: { !context.agentControl.hiddenAgentsSpaceIds.contains($0) }) ?? ids.first else { return }
        NSApp.activate()
        window.switchToSpace(id)
    }

    @objc private func letSleep() {
        context?.powerKeeper.snooze()
    }

    // Lilo's four petals turned into a sun: rays between them and a full heart. Filled, it marks the
    // lid-closed mode, which drains the battery.
    private static let icon = drawIcon(filled: false)
    private static let lidClosedIcon = drawIcon(filled: true)

    private static func drawIcon(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let scale = rect.width / 800
            var base = AffineTransform(translationByX: rect.midX, byY: rect.midY)
            base.scale(scale)
            NSColor.black.set()
            for angle in stride(from: 45.0, to: 360, by: 90) {
                // The logo's petal, in the 800-unit square its SVG is drawn in.
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: -12))
                path.curve(to: NSPoint(x: 114, y: -202), controlPoint1: NSPoint(x: 58, y: -28), controlPoint2: NSPoint(x: 114, y: -108))
                path.curve(to: NSPoint(x: 0, y: -344), controlPoint1: NSPoint(x: 114, y: -286), controlPoint2: NSPoint(x: 64, y: -344))
                path.curve(to: NSPoint(x: -114, y: -202), controlPoint1: NSPoint(x: -64, y: -344), controlPoint2: NSPoint(x: -114, y: -286))
                path.curve(to: NSPoint(x: 0, y: -12), controlPoint1: NSPoint(x: -114, y: -108), controlPoint2: NSPoint(x: -58, y: -28))
                path.close()
                var transform = base
                transform.rotate(byDegrees: angle)
                transform.scale(filled ? 0.98 : 0.92)
                path.transform(using: transform)
                if filled {
                    path.fill()
                } else {
                    path.lineWidth = 44 * scale
                    path.lineJoinStyle = .round
                    path.stroke()
                }
            }
            let rays = NSBezierPath()
            for (from, to) in [((0, -250), (0, -330)), ((0, 250), (0, 330)), ((-250, 0), (-330, 0)), ((250, 0), (330, 0))] {
                rays.move(to: NSPoint(x: from.0, y: from.1))
                rays.line(to: NSPoint(x: to.0, y: to.1))
            }
            rays.transform(using: base)
            rays.lineWidth = 50 * scale
            rays.lineCapStyle = .round
            rays.stroke()
            let heart = NSBezierPath(ovalIn: NSRect(x: rect.midX - 62 * scale, y: rect.midY - 62 * scale, width: 124 * scale, height: 124 * scale))
            if filled {
                NSGraphicsContext.current?.compositingOperation = .clear
            }
            heart.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
