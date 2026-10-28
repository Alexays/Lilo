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
    /// A Document Picture-in-Picture window, made for this size: it lays out at the slot's own size, unscaled.
    private var pictureInPictureView: NSView?
    private(set) var pictureInPictureOpenerId: UUID?
    private var logicalSize = NSSize(width: 1280, height: 800)
    private var slotRect: NSRect?
    /// Distinguishes "slot not mounted yet" (dock just started, chrome still layouting) from
    /// "slot disappeared" (sidebar collapsed), which must re-home the engine.
    private var hadSlot = false
    private weak var chromeView: NSView?

    var engineId: UUID? { engine?.id }
    var isDocking: Bool { engine != nil || pictureInPictureView != nil }

    /// Whole-surface click: bring the docked tab back as the active tab.
    var onReturnToTab: ((UUID) -> Void)?
    /// Corner button: stop showing the dock (the call keeps running in background).
    var onDismiss: ((UUID) -> Void)?
    /// Slot disappeared while docking (sidebar collapsed): the owner re-homes the engine.
    var onSlotLost: ((WKWebViewTab) -> Void)?
    /// Slot disappeared while docking a PiP window: the owner floats it.
    var onPictureInPictureSlotLost: (() -> Void)?
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
            guard let id = self?.engine?.id ?? self?.pictureInPictureOpenerId else { return }
            self?.onReturnToTab?(id)
        }
        controls.onDismiss = { [weak self] in
            guard let id = self?.engine?.id ?? self?.pictureInPictureOpenerId else { return }
            self?.onDismiss?(id)
        }
    }

    func dock(_ engine: WKWebViewTab, logicalSize: NSSize, in contentView: NSView, above sibling: NSView?, chromeView: NSView) {
        if pictureInPictureView != nil {
            undock()
            onPictureInPictureSlotLost?()
        } else if self.engine !== engine {
            _ = undock()
        }
        controls.passesClicksThrough = false
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

    /// Docks a Document Picture-in-Picture window of `openerId`'s page; its own controls stay clickable.
    func dockPictureInPicture(_ view: NSView, openerId: UUID, in contentView: NSView, above sibling: NSView?, chromeView: NSView) {
        if let docked = engine {
            undock()
            onSlotLost?(docked)
        } else if let previous = pictureInPictureView, previous !== view {
            // A PiP window replacing another keeps the slot: no teardown for the chrome to report late.
            previous.removeFromSuperview()
        }
        pictureInPictureView = view
        pictureInPictureOpenerId = openerId
        self.chromeView = chromeView
        controls.passesClicksThrough = true
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
        if let view = pictureInPictureView {
            pictureInPictureView = nil
            pictureInPictureOpenerId = nil
            hadSlot = false
            if view.superview === scaledHost { view.removeFromSuperview() }
            container.isHidden = true
            onDockCleared?()
            return nil
        }
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
        guard slotRect == nil, hadSlot else { return }
        if pictureInPictureView != nil {
            undock()
            onPictureInPictureSlotLost?()
        } else if let engine = undock() {
            onSlotLost?(engine)
        }
    }

    private func applySlot() {
        // The sidebar column runs `sidebarWidth` plus the content inset: the chrome sidebar spans the
        // gutter too, and its resize handle sits there. Insetting the bare sidebar width would leave a
        // gap on the right twice the one on the left.
        let width = sidebarWidth + MainWindowController.contentInset - Self.horizontalInset * 2
        guard isDocking, let slotRect, let chromeView, width > 10 else {
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
        if let pictureInPictureView {
            scaledHost.frame = container.bounds
            scaledHost.bounds = NSRect(origin: .zero, size: container.bounds.size)
            pictureInPictureView.frame = scaledHost.bounds
            return
        }
        // Bounds-based scaling: with the frame at slot size and the bounds at logical size, AppKit
        // renders the subtree at slotWidth/logicalWidth scale with exact slot-aligned geometry
        // (a sublayerTransform would scale about the layer's center anchor and overflow the slot).
        // Fill the slot, cropping the overflowing axis evenly: a page band shorter than the slot would leave
        // transparent strips that cut into the rounded corners.
        let scale = max(width / logicalSize.width, slotRect.height / logicalSize.height)
        let visible = NSSize(width: width / scale, height: slotRect.height / scale)
        scaledHost.frame = container.bounds
        scaledHost.bounds = NSRect(
            x: (logicalSize.width - visible.width) / 2,
            y: (logicalSize.height - visible.height) / 2,
            width: visible.width,
            height: visible.height
        )
        engine?.view.frame = NSRect(origin: .zero, size: logicalSize)
    }
}

/// Swallows clicks over the scaled page (whose hit-testing would land at pre-scale coordinates)
/// and hosts the hover-revealed dismiss button.
private final class DockControlsView: NSView {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Over a PiP window, whose page has its own controls: only the hover buttons take clicks, and returning to
    /// the tab gets a button of its own.
    var passesClicksThrough = false {
        didSet { returnButton.isHidden = true }
    }

    private lazy var returnButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle.fill", accessibilityDescription: "Back to tab".localized)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = "Back to tab".localized
        button.isHidden = true
        button.target = self
        button.action = #selector(returnPressed)
        return button
    }()

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
        addSubview(returnButton)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return passesClicksThrough && hit === self ? nil : hit
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dismissButton.frame = NSRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 20, height: 20)
        returnButton.frame = NSRect(x: bounds.maxX - 48, y: bounds.maxY - 24, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        dismissButton.isHidden = false
        returnButton.isHidden = !passesClicksThrough
    }
    override func mouseExited(with event: NSEvent) {
        dismissButton.isHidden = true
        returnButton.isHidden = true
    }
    override func mouseDown(with event: NSEvent) { onClick?() }

    @objc private func dismissPressed() { onDismiss?() }
    @objc private func returnPressed() { onClick?() }

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
