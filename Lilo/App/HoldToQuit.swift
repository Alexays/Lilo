import AppKit

/// The "Hold the quit shortcut to quit" setting: pressing the quit shortcut shows a HUD and quits only
/// when the keys stay down for `holdDuration` (about a second, as Chrome's warn-before-quit); letting
/// one go, or the app losing focus, cancels. The key event is intercepted in `LiloApplication.sendEvent`,
/// ahead of the menus' key-equivalent match, so it covers the quit action however its shortcut is bound.
/// A quit asked for any other way - the menu item, the Dock, an Apple Event - still quits at once, and at
/// idle nothing runs: the panel, its timer and its observer exist only while the keys are down.
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
    private var holdKeyCode: UInt16 = 0
    private var holdMask: NSEvent.ModifierFlags = []
    private var timer: Timer?
    private var resignObserver: NSObjectProtocol?
    private var hud: HoldToQuitPanel?

    isolated deinit { cancel() }

    /// Called from `sendEvent` for every event; true drops it before the menus can match it.
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            guard isEnabled(), KeyboardShortcuts.action(for: event) == "app.quit" else { return false }
            // A repeat, of a hold or of keys still down after one ended, never begins a hold.
            if !isHolding, !event.isARepeat { begin(with: event) }
            return true
        case .keyUp where isHolding && event.keyCode == holdKeyCode:
            cancel()
            return true
        case .flagsChanged where isHolding:
            if !holdMask.isSubset(of: event.modifierFlags.intersection(Self.modifiers)) { cancel() }
            return false
        default:
            return false
        }
    }

    private func begin(with event: NSEvent) {
        isHolding = true
        holdKeyCode = event.keyCode
        holdMask = event.modifierFlags.intersection(Self.modifiers)
        let hud = self.hud ?? HoldToQuitPanel()
        self.hud = hud
        hud.show(over: event.window ?? NSApp.mainWindow, filling: holdDuration)
        // Common modes: the deadline must hold even while a menu or a trackpad keeps the run loop busy.
        let timer = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Once another app has focus the key-up goes there, so the hold must end with the focus.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func cancel() {
        isHolding = false
        timer?.invalidate()
        timer = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        hud?.orderOut(nil)
    }

    private func fire() {
        cancel()
        quit()
    }
}

/// The hold-to-quit overlay: a dark bezel like the system's, centered over the window the key
/// went to (the screen when none), showing a fill that tracks how much of the hold remains.
private final class HoldToQuitPanel: NSPanel {
    private let bar = HoldToQuitBar()
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

    /// Centers over `window` (the main screen when nil), fades in and fills the bar over `duration`.
    func show(over window: NSWindow?, filling duration: TimeInterval) {
        // The quit shortcut is rebindable: name whichever keys trigger it now.
        let combo = KeyboardShortcuts.display(KeyboardShortcuts.bindings("app.quit").first ?? "⌘q")
        label.stringValue = unsafe String(format: "Hold %@ to Quit".localized, combo)
        setContentSize(contentView?.fittingSize ?? .zero)
        contentView?.layoutSubtreeIfNeeded()
        let anchor = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: anchor.midX - frame.width / 2, y: anchor.midY - frame.height / 2))
        alphaValue = 0
        orderFrontRegardless()
        // A 150 ms fade, which is also what Reduce motion turns every surface's motion into.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        bar.fill(over: duration)
    }
}

/// The hold's fill: a track with a bar Core Animation grows left to right, so no code runs per frame.
private final class HoldToQuitBar: NSView {
    private let fillLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
        fillLayer.backgroundColor = NSColor.labelColor.cgColor
    }

    func fill(over duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.anchorPoint = .zero
        fillLayer.frame = bounds
        fillLayer.cornerRadius = bounds.height / 2
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = bounds.height
        grow.toValue = bounds.width
        grow.duration = duration
        fillLayer.add(grow, forKey: "fill")
    }
}
