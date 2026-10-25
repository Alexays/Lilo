import AppKit

/// Docks an in-call tab's live view at the sidebar bottom, scaled by a layer transform: shrinking the view would reflow the page to a
/// phone layout. The chrome streams the slot rect under `zoneId`, so sidebar resize and collapse follow.
@MainActor
final class TabDockController {
    static let zoneId = "pip-dock"
    /// Mirrors the slot's CSS side margin in PipDock.svelte, itself the sidebar row inset.
    static let horizontalInset: CGFloat = 10

    /// Authoritative sidebar width: horizontal geometry comes from here, not the slot rect, because a rect measured mid-transform (collapse,
    /// space swipe) is never re-reported and would leave the dock offset. The vertical band still comes from the rect.
    var sidebarWidth: CGFloat = 0 {
        didSet {
            guard sidebarWidth != oldValue else { return }
            applySlot()
        }
    }
    var sidebarOnRight = false {
        didSet {
            guard sidebarOnRight != oldValue else { return }
            applySlot()
        }
    }

    private let container = NSView()
    /// Hosts the engine view; carries the scale so the sibling controls stay unscaled.
    private let scaledHost = NSView()
    private let controls = DockControlsView()
    private var engine: WKWebViewTab?
    private var logicalSize = NSSize(width: 1280, height: 800)
    private var slotRect: NSRect?
    /// Distinguishes "slot not mounted yet" (dock just started, chrome still layouting) from
    /// "slot disappeared" (sidebar collapsed), which must re-home the engine.
    private var hadSlot = false
    private weak var chromeView: NSView?

    var engineId: UUID? { engine?.id }
    var isDocking: Bool { engine != nil }

    /// Whole-surface click: bring the docked tab back as the active tab.
    var onReturnToTab: ((UUID) -> Void)?
    /// Corner button: stop showing the dock (the call keeps running in background).
    var onDismiss: ((UUID) -> Void)?
    /// Slot disappeared while docking (sidebar collapsed): the owner re-homes the engine.
    var onSlotLost: ((WKWebViewTab) -> Void)?
    /// Fired whenever the dock actually stops hosting an engine, whatever the reason (tab closed,
    /// returned to, dismissed, slot lost). The single place the chrome's slot is torn down.
    var onDockCleared: (() -> Void)?

    init() {
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.isHidden = true
        // Clip at the host too: the engine's remote-hosted layer must never paint past the slot.
        scaledHost.wantsLayer = true
        scaledHost.layer?.masksToBounds = true
        container.addSubview(scaledHost)
        container.addSubview(controls)
        controls.onClick = { [weak self] in
            guard let id = self?.engine?.id else { return }
            self?.onReturnToTab?(id)
        }
        controls.onDismiss = { [weak self] in
            guard let id = self?.engine?.id else { return }
            self?.onDismiss?(id)
        }
    }

    func dock(_ engine: WKWebViewTab, logicalSize: NSSize, in contentView: NSView, above sibling: NSView?, chromeView: NSView) {
        if self.engine !== engine { _ = undock() }
        self.engine = engine
        self.logicalSize = logicalSize.width > 100 && logicalSize.height > 100 ? logicalSize : NSSize(width: 1280, height: 800)
        self.chromeView = chromeView
        let view = engine.view
        view.autoresizingMask = []
        view.isHidden = false
        scaledHost.addSubview(view)
        if container.superview !== contentView {
            contentView.addSubview(container, positioned: .above, relativeTo: sibling)
        }
        applySlot()
    }

    /// Re-adopts the docked engine's view after a space switch: parking detaches every engine
    /// view of the leaving space, the dock's included.
    func reattachIfNeeded() {
        guard let engine, engine.view.superview !== scaledHost else { return }
        engine.view.isHidden = false
        scaledHost.addSubview(engine.view)
        applySlot()
    }

    /// Detaches the docked view and returns its engine so the caller can re-home it.
    @discardableResult
    func undock() -> WKWebViewTab? {
        guard let engine else { return nil }
        self.engine = nil
        hadSlot = false
        engine.view.removeFromSuperview()
        container.isHidden = true
        onDockCleared?()
        return engine
    }

    /// Fed from the interactive-zone stream (chrome viewport coordinates, top-left origin).
    func zonesChanged(_ zones: [String: NSRect]) {
        guard slotRect != zones[Self.zoneId] else { return }
        slotRect = zones[Self.zoneId]
        applySlot()
        if slotRect == nil, hadSlot, let engine = undock() {
            onSlotLost?(engine)
        }
    }

    private func applySlot() {
        // The sidebar column runs `sidebarWidth` plus the content inset: the chrome sidebar spans the
        // gutter too, and its resize handle sits there. Insetting the bare sidebar width would leave a
        // gap on the right twice the one on the left.
        let width = sidebarWidth + MainWindowController.contentInset - Self.horizontalInset * 2
        guard engine != nil, let slotRect, let chromeView, width > 10 else {
            container.isHidden = true
            return
        }
        hadSlot = true
        container.frame = NSRect(
            x: sidebarOnRight ? chromeView.bounds.width - sidebarWidth - MainWindowController.contentInset + Self.horizontalInset : Self.horizontalInset,
            y: chromeView.bounds.height - slotRect.maxY,
            width: width,
            height: slotRect.height
        )
        container.isHidden = false
        controls.frame = container.bounds
        // Bounds-based scaling: with the frame at slot size and the bounds at logical size, AppKit
        // renders the subtree at slotWidth/logicalWidth scale with exact slot-aligned geometry
        // (a sublayerTransform would scale about the layer's center anchor and overflow the slot).
        let scale = width / logicalSize.width
        scaledHost.frame = container.bounds
        scaledHost.bounds = NSRect(
            x: 0,
            // Center the visible band vertically; a page taller than the slot crops evenly.
            y: (logicalSize.height - container.bounds.height / scale) / 2,
            width: logicalSize.width,
            height: container.bounds.height / scale
        )
        engine?.view.frame = NSRect(origin: .zero, size: logicalSize)
    }
}

/// Swallows clicks over the scaled page (whose hit-testing would land at pre-scale coordinates)
/// and hosts the hover-revealed dismiss button.
private final class DockControlsView: NSView {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let dismissButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide call preview".localized)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = "Hide call preview".localized
        button.isHidden = true
        return button
    }()

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Back to tab".localized
        dismissButton.target = self
        dismissButton.action = #selector(dismissPressed)
        addSubview(dismissButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dismissButton.frame = NSRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { dismissButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { dismissButton.isHidden = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    @objc private func dismissPressed() { onDismiss?() }

    // VoiceOver never hovers, so the dismiss button it cannot reach is offered as an action.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Back to tab".localized }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Hide call preview".localized) { [weak self] in
            self?.onDismiss?()
            return true
        }]
    }
}
