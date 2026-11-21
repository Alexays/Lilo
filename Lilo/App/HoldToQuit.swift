import AppKit

/// The "Hold ⌘Q to quit" setting: pressing the quit shortcut shows a HUD and quits only when the
/// keys stay down for `holdDuration` (about a second, as Chrome's warn-before-quit); letting one go
/// cancels. The key event is intercepted in `LiloApplication.sendEvent`, ahead of the menus'
/// key-equivalent match, so it covers the quit action however its shortcut is bound. A quit asked
/// for any other way - the menu item, the Dock, an Apple Event - still quits at once, and at idle
/// nothing runs: the panel and its one timer exist only while the keys are down.
@MainActor
final class HoldToQuit {
    static let defaultHoldDuration: TimeInterval = 1
    private static let modifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// Reads the setting late: the store opens after the first window.
    var isEnabled: () -> Bool = {
        (NSApp.delegate as? AppDelegate)?.browserContext.settingsStore?.holdToQuit == true
    }
    /// Test seam: what a completed hold does.
    var quit: () -> Void = { NSApp.terminate(nil) }
    var holdDuration = defaultHoldDuration
    private(set) var isHolding = false
    /// The keys stayed down through a completed hold: their repeats must not begin another.
    private var awaitingRelease = false
    private var holdMask: NSEvent.ModifierFlags = []
    private var startedAt: Date?
    private var timer: Timer?
    private var hud: HoldToQuitPanel?

    isolated deinit { timer?.invalidate() }

    /// Called from `sendEvent` for every event; true drops it before the menus can match it.
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown where Self.isQuit(event):
            guard isEnabled() else { return false }
            // A repeat of the held keys, or keys still down from a finished hold, never re-begins.
            if !isHolding, !awaitingRelease { begin(with: event) }
            return true
        case .keyUp where Self.isQuit(event):
            awaitingRelease = false
            if isHolding { cancel() }
            return true
        case .flagsChanged:
            if !holdMask.isSubset(of: event.modifierFlags.intersection(Self.modifiers)) {
                awaitingRelease = false
                if isHolding { cancel() }
            }
            return false
        default:
            return false
        }
    }

    private static func isQuit(_ event: NSEvent) -> Bool {
        KeyboardShortcuts.action(for: event) == "app.quit"
    }

    private func begin(with event: NSEvent) {
        isHolding = true
        holdMask = event.modifierFlags.intersection(Self.modifiers)
        startedAt = Date()
        let hud = self.hud ?? HoldToQuitPanel()
        self.hud = hud
        hud.show(over: event.window ?? NSApp.mainWindow)
        // Common modes: the deadline must hold even while a menu or a trackpad keeps the run loop busy.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isHolding, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed < holdDuration else { return fire() }
        hud?.bar.progress = elapsed / holdDuration
    }

    private func cancel() {
        isHolding = false
        timer?.invalidate()
        timer = nil
        hud?.orderOut(nil)
    }

    private func fire() {
        cancel()
        awaitingRelease = true
        quit()
    }
}

/// The "Hold ⌘Q to Quit" overlay: a dark bezel like the system's, centered over the window the key
/// went to (the screen when none), showing a fill that tracks how much of the hold remains.
private final class HoldToQuitPanel: NSPanel {
    let bar = HoldToQuitBar()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        bar.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Chrome's prompt is dark whatever the theme, like the system bezel: a dark vibrancy panel
        // gives the same feel and keeps the label readable on any backdrop.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            bar.widthAnchor.constraint(equalToConstant: 180),
            bar.heightAnchor.constraint(equalToConstant: 5)
        ])
        contentView = effect
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Centers over `window` (the main screen when nil) and fades in, except under Reduce motion.
    func show(over window: NSWindow?) {
        // The quit shortcut is rebindable: name whichever keys trigger it now.
        let combo = KeyboardShortcuts.display(KeyboardShortcuts.bindings("app.quit").first ?? "⌘q")
        label.stringValue = unsafe String(format: "Hold %@ to Quit".localized, combo)
        bar.progress = 0
        setContentSize(contentView?.fittingSize ?? .zero)
        let anchor = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: anchor.midX - frame.width / 2, y: anchor.midY - frame.height / 2))
        orderFrontRegardless()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }
}

/// The hold's fill: a track with a bar growing left to right as `progress` goes to 1.
private final class HoldToQuitBar: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard progress > 0 else { return }
        var fill = bounds
        fill.size.width = max(bounds.height, bounds.width * min(progress, 1))
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
