import AppKit
import WebKit

/// The draggable gap between the two panes of a split view. It paints the window frame color
/// and bites the pane corners beside it, so each pane reads as its own rounded card.
final class SplitDividerView: NSView {
    /// Matches the window frame's inset around the content.
    static let width: CGFloat = 8
    private static let hoverFadeDuration: TimeInterval = 0.15

    /// The panes are stacked: the divider runs across and drags up and down.
    var isVertical = false {
        didSet {
            guard isVertical != oldValue else { return }
            applyCornerPaths()
            layoutLayers()
        }
    }
    /// The rectangle this divider cuts in two, in its superview's coordinates.
    var cutBounds = NSRect.zero
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onSuperviewResize: (() -> Void)?
    /// Set on an edge that resizes like the sidebar's: hovering tints the whole divider with it, as the sidebar's edge
    /// does, instead of showing the pill.
    var hoverTint: NSColor? {
        didSet {
            applyHandleColor()
            layoutLayers()
        }
    }

    private let fill = CALayer()
    private let handle = CALayer()
    /// Leading pane's two corners, then the trailing pane's.
    private let corners = (0..<4).map { _ in CAShapeLayer() }
    private var frameColor = NSColor.clear
    private var fillColor = NSColor.clear
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(fill)
        handle.opacity = 0
        layer?.addSublayer(handle)
        for corner in corners {
            corner.fillRule = .evenOdd
            corner.masksToBounds = true
            layer?.addSublayer(corner)
        }
        applyCornerPaths()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = unsafe window?.backingScaleFactor ?? 2
        corners.forEach { $0.contentsScale = scale }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        onSuperviewResize?()
    }

    /// `gapColor` overrides the gap's own paint: the side panel's divider leaves it to the frame's band.
    func setFrameColor(_ color: NSColor, gapColor: NSColor? = nil, animated: Bool) {
        let painted = gapColor ?? color
        guard color != frameColor || painted != fillColor else { return }
        frameColor = color
        fillColor = painted
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(WindowFrameView.colorFadeDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.backgroundColor = painted.cgColor
        corners.forEach { $0.fillColor = color.cgColor }
        applyHandleColor()
        CATransaction.commit()
    }

    private func applyHandleColor() {
        if let hoverTint {
            // The sidebar's `--accent-tint-12`, over the frame color the divider paints.
            handle.backgroundColor = hoverTint.withAlphaComponent(0.12).cgColor
            return
        }
        let srgb = frameColor.usingColorSpace(.sRGB) ?? frameColor
        handle.backgroundColor = (srgb.blended(withFraction: 0.16, of: srgb.brightnessComponent > 0.5 ? .black : .white) ?? srgb).cgColor
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.hoverFadeDuration)
        handle.opacity = hovered ? 1 : 0
        CATransaction.commit()
    }

    /// Unflipped layer coordinates, as in `WindowFrameView`: the circle center sits on the corner
    /// square's vertex diagonal to the pane corner. The bites overhang the divider into the panes.
    private func applyCornerPaths() {
        let r = WindowFrameView.contentCornerRadius
        let centers = isVertical
            ? [CGPoint(x: r, y: r), CGPoint(x: 0, y: r), CGPoint(x: r, y: 0), CGPoint(x: 0, y: 0)]
            : [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: r), CGPoint(x: r, y: 0), CGPoint(x: r, y: r)]
        for (corner, center) in zip(corners, centers) {
            corner.path = WindowFrameView.cornerBitePath(radius: r, circleCenter: center)
        }
    }

    private func layoutLayers() {
        let r = WindowFrameView.contentCornerRadius
        let w = bounds.width, h = bounds.height
        let frames = isVertical
            ? [CGRect(x: 0, y: h, width: r, height: r), CGRect(x: w - r, y: h, width: r, height: r),
               CGRect(x: 0, y: -r, width: r, height: r), CGRect(x: w - r, y: -r, width: r, height: r)]
            : [CGRect(x: -r, y: h - r, width: r, height: r), CGRect(x: -r, y: 0, width: r, height: r),
               CGRect(x: w, y: h - r, width: r, height: r), CGRect(x: w, y: 0, width: r, height: r)]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        if hoverTint != nil {
            handle.frame = bounds
            handle.cornerRadius = 0
        } else {
            // Runs between the pane corners, where both edges are straight.
            handle.frame = isVertical ? bounds.insetBy(dx: r, dy: 0) : bounds.insetBy(dx: 0, dy: r)
            handle.cornerRadius = min(handle.frame.width, handle.frame.height) / 2
        }
        for (corner, frame) in zip(corners, frames) { corner.frame = frame }
        CATransaction.commit()
    }

    override func cursorUpdate(with event: NSEvent) { (isVertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }
    override func mouseMoved(with event: NSEvent) { (isVertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }

    override func mouseDragged(with event: NSEvent) {
        guard let superview = unsafe superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

/// A thin accent outline over the focused pane of a split; never takes events.
final class SplitFocusRingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = WindowFrameView.contentCornerRadius
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
    }

    /// Fades in on the pane it just moved to and pulses once, thicker and brighter, to show the switch.
    /// Layer properties only: AppKit syncs a layer-backed view's geometry late, so a frame animation
    /// would start from the previous pane.
    func pulse() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.08
        let brighten = CAKeyframeAnimation(keyPath: "borderColor")
        brighten.values = [0.55, 1, 0.55].map { NSColor.controlAccentColor.withAlphaComponent($0).cgColor }
        var animations: [CAAnimation] = [fade, brighten]
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let swell = CAKeyframeAnimation(keyPath: "borderWidth")
            swell.values = [2, 4, 2]
            animations.append(swell)
        }
        for case let keyframes as CAKeyframeAnimation in animations {
            keyframes.keyTimes = [0, 0.3, 1]
            keyframes.duration = 0.4
            keyframes.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = 0.4
        layer.add(group, forKey: "pulse")
    }
}

/// The strip along a split pane's top edge, where the pointer reveals a pill: × takes the pane out
/// of the split, the arrows make it the only tab. It floats over the pane, so showing it never moves anything.
final class SplitPaneHandleView: NSView {
    static let pillSize = NSSize(width: 66, height: 26)
    /// How far below the pane's top edge the pointer still reveals the pill.
    static let revealHeight: CGFloat = 48
    private static let fadeDuration: TimeInterval = 0.15

    var onClose: (() -> Void)?
    var onMaximize: (() -> Void)?
    /// Dragging the pill moves the pane inside the split; the events carry the window point.
    var onDragStart: (() -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: ((NSEvent) -> Void)?

    private var revealed = false
    private var isDragging = false
    /// Opaque, as a tab's modal panel: a translucent material vanished over dark pages.
    private let pill = NSBox()
    private let closeButton = NSButton()
    private let maximizeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        pill.boxType = .custom
        pill.titlePosition = .noTitle
        pill.fillColor = .windowBackgroundColor
        pill.borderColor = .separatorColor
        pill.borderWidth = 1
        pill.cornerRadius = Self.pillSize.height / 2
        addSubview(pill)
        for (button, symbol, action, label) in [
            (closeButton, "xmark", #selector(closePressed), "Close Split Pane".localized),
            (maximizeButton, "arrow.up.left.and.arrow.down.right", #selector(maximizePressed), "Maximize Split Pane".localized)
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.contentTintColor = .labelColor
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
            button.setButtonType(.momentaryPushIn)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let size = Self.pillSize
        pill.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - size.height - 6, width: size.width, height: size.height)
        for (button, x) in [(closeButton, CGFloat(5)), (maximizeButton, CGFloat(37))] {
            button.frame = NSRect(x: pill.frame.minX + x, y: pill.frame.minY + (size.height - 22) / 2, width: 24, height: 22)
        }
    }

    /// The buttons take clicks and the pill around them is the pane's drag grip; the rest of the
    /// strip falls through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard revealed, let hit = super.hitTest(point) else { return nil }
        if hit is NSButton { return hit }
        return hit.isDescendant(of: pill) ? self : nil
    }

    /// The grip shows the grab hand: the pill's pixels outside the two buttons (its 5pt edges and
    /// the 8pt gap between them).
    override func resetCursorRects() {
        super.resetCursorRects()
        guard revealed else { return }
        let pill = pill.frame
        for (x, width) in [(CGFloat(0), CGFloat(5)), (29, 8), (61, 5)] {
            addCursorRect(NSRect(x: pill.minX + x, y: pill.minY, width: width, height: pill.height), cursor: .openHand)
        }
    }

    override func cursorUpdate(with event: NSEvent) { (isDragging ? NSCursor.closedHand : NSCursor.openHand).set() }

    override func mouseDragged(with event: NSEvent) {
        if !isDragging {
            isDragging = true
            onDragStart?()
        }
        NSCursor.closedHand.set()
        onDragMove?(event)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { onDragEnd?(event) }
        isDragging = false
    }

    func setRevealed(_ revealed: Bool) {
        guard revealed != self.revealed else { return }
        self.revealed = revealed
        unsafe window?.invalidateCursorRects(for: self)
        // A fade, so Reduce motion keeps it; a plain alphaValue set on a layer-backed view would not animate.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = revealed ? 1 : 0
        }
    }

    /// The hover feed only sees moves inside the window: a pointer leaving it from the strip hides the pill here.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    override func mouseExited(with event: NSEvent) { setRevealed(false) }

    @objc private func closePressed() { onClose?() }
    @objc private func maximizePressed() { onMaximize?() }
}

/// The frame-colored ring a split keeps around its panes: it lifts them off the chrome over the
/// page and the window frame, and bites their outer corners as the dividers bite the inner ones,
/// so every pane stays a rounded card. Paint only, never takes events.
final class SplitMarginView: NSView {
    /// Half a divider's gap: a pane sits closer to the frame than to another pane.
    static let width = SplitDividerView.width / 2

    private let band = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        band.fillRule = .evenOdd
        layer?.addSublayer(band)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Standalone sublayers don't inherit the backing scale: see `WindowFrameView`.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        band.contentsScale = unsafe window?.backingScaleFactor ?? 2
    }

    /// The frame is the panes' rectangle: the band rings it and bites its corners.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let radius = WindowFrameView.contentCornerRadius
        let path = CGMutablePath()
        path.addRect(bounds.insetBy(dx: -Self.width, dy: -Self.width))
        path.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.path = path
        CATransaction.commit()
    }

    /// Matches the dividers' fade.
    func setFrameColor(_ color: NSColor, animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(WindowFrameView.colorFadeDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        band.fillColor = color.cgColor
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Sits behind a web pane, at the pane's frame. WebKit docks the Web Inspector over the whole superview of the
/// page's attachment view, so each web pane gets a superview of its own size and the page follows `anchor`.
final class SplitPaneDockView: NSView {
    /// The page's place in the pane, which WebKit sizes beside the docked inspector.
    private let anchor = NSView()
    private(set) weak var webView: WKWebView?

    /// Nil when WebKit has no attachment view to set: the pane then frames its page itself.
    init?(webView: WKWebView, frame: NSRect) {
        self.webView = webView
        super.init(frame: frame)
        // Sized before WebKit sees it: an attached inspector docks against it at once.
        anchor.frame = bounds
        anchor.autoresizingMask = [.width, .height]
        addSubview(anchor)
        guard WebViewPrivateAccessors(webView).setInspectorAttachmentView(anchor) else { return nil }
        NotificationCenter.default.addObserver(self, selector: #selector(syncPage), name: NSView.frameDidChangeNotification, object: anchor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        syncPage()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncPage()
    }

    @objc private func syncPage() {
        guard let webView, let superview = unsafe superview else { return }
        let frame = superview.convert(anchor.frame, from: self)
        if webView.frame != frame { webView.frame = frame }
    }

    /// Hands the inspector back to the page's own superview and leaves the screen.
    func detach() {
        if let webView { _ = WebViewPrivateAccessors(webView).setInspectorAttachmentView(nil) }
        removeFromSuperview()
    }
}

/// Lays the displayed split out in the content area: pane frames, one divider per cut and the focus
/// ring. Also finds the pane under the pointer and tells the chrome where each pane sits.
@MainActor
final class SplitPanesController {
    /// Smallest pane a divider drag may leave, along the axis of the cut.
    private static let minimumPaneLength: CGFloat = 200

    private unowned let controller: MainWindowController
    /// The split currently laid out in the content area.
    private(set) var split: SplitGroup?
    /// One divider per cut, keyed by its path.
    private(set) var dividers: [[Bool]: SplitDividerView] = [:]
    /// One dock per web pane, keyed by its tab.
    private(set) var docks: [UUID: SplitPaneDockView] = [:]
    /// The layout while a divider is being dragged; persisted on the split folder on release.
    private var liveLayout: SplitLayout?
    /// One hover handle per pane, keyed by its tab.
    private var handles: [UUID: SplitPaneHandleView] = [:]
    /// Whether the last hover sample was on the panes, so moves elsewhere stop after one clear.
    private var isHovering = false
    /// Pane frames last sent to the chrome, as shares of the content area.
    var sentPaneFrames: [UUID: NSRect] = [:]
    private var focusRing: SplitFocusRingView?
    private var marginView: SplitMarginView?
    private weak var pointerTarget: NSView?
    /// Whether the drag with this sequence number carries a web link; read once per drag.
    private var linkDragCache: (sequence: Int, isWebLink: Bool)?

    init(controller: MainWindowController) { self.controller = controller }

    /// Lays `split` out over the pane views already in the container, the focus ring above them.
    func show(_ split: SplitGroup) {
        let ring = focusRing ?? SplitFocusRingView()
        focusRing = ring
        // Above every pane and divider, wherever an activation just re-added one.
        controller.contentContainerView.addSubview(ring, positioned: .above, relativeTo: nil)
        if self.split != split { liveLayout = nil }
        self.split = split
        applyFrames()
    }

    /// Takes the dividers and the ring off screen; the panes are the controller's to remove.
    func clear() {
        cancelPaneDrag()
        split = nil
        liveLayout = nil
        dividers.values.forEach { $0.removeFromSuperview() }
        dividers = [:]
        docks.values.forEach { $0.detach() }
        docks = [:]
        handles.values.forEach { $0.removeFromSuperview() }
        handles = [:]
        focusRing?.removeFromSuperview()
        marginView?.removeFromSuperview()
        marginView = nil
        sendPaneFrames([:])
    }

    /// Puts a pane's view over whatever stays shown under the content, and under the dividers and the focus ring.
    func addPane(_ view: NSView, below sibling: NSView? = nil) {
        let container = controller.contentContainerView
        container.addSubview(view, positioned: .below, relativeTo: sibling ?? marginView ?? container.subviews.first { $0 is SplitDividerView } ?? focusRing)
    }

    private func makeDivider(path: [Bool]) -> SplitDividerView {
        let divider = SplitDividerView()
        divider.setFrameColor(controller.currentFrameColor, animated: false)
        // The root cut always exists while a split shows, so it alone relays container resizes.
        if path.isEmpty {
            // AppKit skips resize(withOldSuperviewSize:) on a subview with an empty mask; the frame it sets is overwritten anyway.
            divider.autoresizingMask = [.width, .height]
            divider.onSuperviewResize = { [weak self] in self?.applyFrames(animatesFocus: false) }
        }
        divider.onDrag = { [weak self, weak divider] point in
            guard let self, let divider, let layout = liveLayout ?? split?.layout else { return }
            let cut = divider.cutBounds
            let length = (divider.isVertical ? cut.height : cut.width) - SplitDividerView.width
            guard length > 0, case let .split(vertical, _, first, second)? = layout.subtree(at: path) else { return }
            // The first part is on top, and an unflipped view counts y from the bottom.
            let offset = !vertical ? point.x - cut.minX
                : controller.contentContainerView.isFlipped ? point.y - cut.minY : cut.maxY - point.y
            let lowest = Self.minimumLength(of: first, vertical: vertical) / length
            let highest = 1 - Self.minimumLength(of: second, vertical: vertical) / length
            guard lowest <= highest else { return }
            let ratio = min(max((offset - SplitDividerView.width / 2) / length, lowest), highest)
            liveLayout = layout.updatingCut(at: path) { _, current in current = Double(ratio) }
            applyFrames(animatesFocus: false)
        }
        divider.onDragEnd = { [weak self] in
            guard let self, let split, let layout = liveLayout, let spaceId = controller.tabManager.currentSpaceId else { return }
            // A changed layout reaches the screen through layoutSplitContent; one equal to the stored
            // layout is already there, and a rejected one snaps back.
            liveLayout = nil
            if (try? controller.applyBrowserCommand(.setSplitLayout(spaceId: spaceId, folderId: split.folderId, layout: layout))) == nil {
                applyFrames(animatesFocus: false)
            }
        }
        dividers[path] = divider
        return divider
    }

    private func makeHandle(for tabId: UUID) -> SplitPaneHandleView {
        let handle = SplitPaneHandleView(frame: .zero)
        handle.onClose = { [weak self] in self?.controller.unsplitTab(tabId) }
        handle.onMaximize = { [weak self] in self?.controller.maximizeSplitPane(tabId) }
        handle.onDragStart = { [weak self] in self?.beginPaneDrag(tabId) }
        handle.onDragMove = { [weak self] in self?.updatePaneDrag($0) }
        handle.onDragEnd = { [weak self] in self?.endPaneDrag($0) }
        handles[tabId] = handle
        return handle
    }

    /// A pane picked up by its pill. The chrome draws the drop targets and applies the drop;
    /// this side only streams the pointer as content-area shares, the same space as `sentPaneFrames`.
    private var paneDragTabId: UUID?
    private var paneDragKeyMonitor: Any?

    private func beginPaneDrag(_ tabId: UUID) {
        paneDragTabId = tabId
        paneDragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.paneDragTabId != nil, event.keyCode == 53 else { return event }
            self.cancelPaneDrag()
            return nil
        }
    }

    private func paneDragShare(_ windowPoint: NSPoint) -> (x: Double, y: Double)? {
        let container = controller.contentContainerView
        guard container.bounds.width > 0, container.bounds.height > 0 else { return nil }
        let local = container.convert(windowPoint, from: nil)
        let y = container.isFlipped ? local.y : container.bounds.height - local.y
        return (Double(local.x / container.bounds.width), Double(y / container.bounds.height))
    }

    private func sendPaneDrag(_ phase: String, windowPoint: NSPoint? = nil) {
        guard let tabId = paneDragTabId else { return }
        let share = windowPoint.flatMap(paneDragShare) ?? (x: 0, y: 0)
        controller.bridgeRouter.send(event: "splitPaneDrag", data: [
            "tabId": tabId.uuidString, "phase": phase, "x": share.x, "y": share.y
        ])
    }

    private func updatePaneDrag(_ event: NSEvent) { sendPaneDrag("move", windowPoint: event.locationInWindow) }

    private func endPaneDrag(_ event: NSEvent) {
        sendPaneDrag("end", windowPoint: event.locationInWindow)
        finishPaneDrag()
    }

    private func cancelPaneDrag() {
        sendPaneDrag("cancel")
        finishPaneDrag()
    }

    private func finishPaneDrag() {
        paneDragTabId = nil
        if let monitor = paneDragKeyMonitor { NSEvent.removeMonitor(monitor) }
        paneDragKeyMonitor = nil
    }

    /// The handle's strip: the top of the pane, inside it so it never covers a divider.
    private static func handleFrame(in pane: NSRect) -> NSRect {
        let height = min(SplitPaneHandleView.revealHeight, pane.height)
        return NSRect(x: pane.minX, y: pane.maxY - height, width: pane.width, height: height)
    }

    /// How short a part can get along a cut's axis: its panes' minimum, plus the dividers between
    /// panes stacked along that same axis.
    private static func minimumLength(of layout: SplitLayout, vertical: Bool) -> CGFloat {
        guard case let .split(isVertical, _, first, second) = layout else { return minimumPaneLength }
        let firstLength = minimumLength(of: first, vertical: vertical)
        let secondLength = minimumLength(of: second, vertical: vertical)
        return isVertical == vertical ? firstLength + SplitDividerView.width + secondLength : max(firstLength, secondLength)
    }

    /// Each pane's frame and each cut's divider frame and bounds, in the container's coordinates.
    static func frames(
        _ layout: SplitLayout, in rect: NSRect, flipped: Bool, path: [Bool],
        panes: inout [UUID: NSRect], cuts: inout [[Bool]: (divider: NSRect, bounds: NSRect, vertical: Bool)]
    ) {
        guard case let .split(vertical, ratio, first, second) = layout else {
            if case let .pane(tabId) = layout { panes[tabId] = rect }
            return
        }
        let gap = SplitDividerView.width
        let firstRect: NSRect, divider: NSRect, secondRect: NSRect
        if vertical {
            let firstHeight = ((rect.height - gap) * CGFloat(ratio)).rounded()
            let secondHeight = rect.height - firstHeight - gap
            // First on top, whichever way the container counts y.
            firstRect = NSRect(x: rect.minX, y: flipped ? rect.minY : rect.maxY - firstHeight, width: rect.width, height: firstHeight)
            divider = NSRect(x: rect.minX, y: flipped ? rect.minY + firstHeight : rect.minY + secondHeight, width: rect.width, height: gap)
            secondRect = NSRect(x: rect.minX, y: flipped ? rect.maxY - secondHeight : rect.minY, width: rect.width, height: secondHeight)
        } else {
            let firstWidth = ((rect.width - gap) * CGFloat(ratio)).rounded()
            firstRect = NSRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            divider = NSRect(x: rect.minX + firstWidth, y: rect.minY, width: gap, height: rect.height)
            secondRect = NSRect(x: divider.maxX, y: rect.minY, width: rect.maxX - divider.maxX, height: rect.height)
        }
        cuts[path] = (divider, rect, vertical)
        frames(first, in: firstRect, flipped: flipped, path: path + [false], panes: &panes, cuts: &cuts)
        frames(second, in: secondRect, flipped: flipped, path: path + [true], panes: &panes, cuts: &cuts)
    }

    func applyFrames(animatesFocus: Bool = true) {
        guard let split else { return }
        let tabManager = controller.tabManager
        let container: NSView = controller.contentContainerView
        var panes: [UUID: NSRect] = [:]
        var cuts: [[Bool]: (divider: NSRect, bounds: NSRect, vertical: Bool)] = [:]
        // The margin keeps the panes off the chrome over the page and the window frame.
        let outer = container.bounds.insetBy(dx: SplitMarginView.width, dy: SplitMarginView.width)
        Self.frames(liveLayout ?? split.layout, in: outer, flipped: container.isFlipped, path: [], panes: &panes, cuts: &cuts)
        // Over the panes, under the focus ring: the margin bites the panes' outer corners.
        let margin = marginView ?? SplitMarginView()
        marginView = margin
        margin.frame = outer
        if unsafe margin.superview !== container {
            margin.setFrameColor(controller.currentFrameColor, animated: false)
            container.addSubview(margin, positioned: .below, relativeTo: focusRing)
        }
        for (path, divider) in dividers where cuts[path] == nil {
            divider.removeFromSuperview()
            dividers[path] = nil
        }
        for (path, cut) in cuts {
            let divider = dividers[path] ?? makeDivider(path: path)
            divider.isVertical = cut.vertical
            divider.cutBounds = cut.bounds
            divider.frame = cut.divider
            if unsafe divider.superview !== container {
                container.addSubview(divider, positioned: .below, relativeTo: focusRing)
            }
        }
        for (tabId, dock) in docks where panes[tabId] == nil || dock.webView !== tabManager.loadedContentView(forTabId: tabId) {
            dock.detach()
            docks[tabId] = nil
        }
        for (tabId, frame) in panes {
            guard let view = tabManager.loadedContentView(forTabId: tabId) else { continue }
            view.autoresizingMask = []
            guard let dock = docks[tabId] ?? (view as? WKWebView).flatMap({ SplitPaneDockView(webView: $0, frame: frame) }) else {
                view.frame = frame
                continue
            }
            docks[tabId] = dock
            dock.frame = frame
            if unsafe dock.superview !== container {
                addPane(dock, below: unsafe view.superview === container ? view : nil)
            }
        }
        for (tabId, handle) in handles where panes[tabId] == nil {
            handle.removeFromSuperview()
            handles[tabId] = nil
        }
        for (tabId, frame) in panes where tabManager.loadedContentView(forTabId: tabId) != nil {
            let handle = handles[tabId] ?? makeHandle(for: tabId)
            handle.frame = Self.handleFrame(in: frame)
            if unsafe handle.superview !== container {
                container.addSubview(handle, positioned: .above, relativeTo: nil)
            }
        }
        // A divider drag reports its panes once, on release.
        if liveLayout == nil { sendPaneFrames(panes) }
        guard let ring = focusRing, let focused = tabManager.activeOpenTabId.flatMap({ panes[$0] }) else { return }
        // Only an activation animates; resizes and divider drags follow at once.
        guard animatesFocus, ring.frame != .zero, ring.frame != focused else {
            ring.frame = focused
            return
        }
        // The old ring fades where it is and the new one pulses on its pane: nothing crosses the content.
        let ghost = SplitFocusRingView(frame: ring.frame)
        container.addSubview(ghost, positioned: .below, relativeTo: ring)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { ghost.removeFromSuperview() } })
        ring.frame = focused
        ring.pulse()
    }

    /// Tells the chrome where each pane sits, as shares of the content area from its top-left
    /// corner, so a tab dragged over the page can aim at one. Empty when no split shows.
    private func sendPaneFrames(_ frames: [UUID: NSRect]) {
        let bounds = controller.contentContainerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let flipped = controller.contentContainerView.isFlipped
        // Shares hold through a window resize, so only a new arrangement goes out.
        let shares = frames.mapValues { frame in
            NSRect(
                x: (frame.minX / bounds.width * 1000).rounded() / 1000,
                y: ((flipped ? frame.minY : bounds.height - frame.maxY) / bounds.height * 1000).rounded() / 1000,
                width: (frame.width / bounds.width * 1000).rounded() / 1000,
                height: (frame.height / bounds.height * 1000).rounded() / 1000
            )
        }
        guard shares != sentPaneFrames else { return }
        sentPaneFrames = shares
        let order = split?.layout.paneIds ?? []
        controller.bridgeRouter.send(event: "splitPanesChanged", data: ["panes": order.compactMap { id in
            shares[id].map { ["tabId": id.uuidString, "x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        }])
    }

    /// The pane abutting `tabId`'s frame on `direction`'s side, in the top-left-origin
    /// shares `sentPaneFrames` uses. Used by the menu's pane moves; a drag aims by edge instead.
    static func neighborPane(of tabId: UUID, in frames: [UUID: NSRect], direction: SplitPaneDirection) -> UUID? {
        guard let frame = frames[tabId] else { return nil }
        var best: (id: UUID, edge: CGFloat, cross: CGFloat)?
        for (id, cand) in frames where id != tabId {
            let overlap: CGFloat, edge: CGFloat, cross: CGFloat, reaches: Bool
            switch direction {
            case .left:
                overlap = min(frame.maxY, cand.maxY) - max(frame.minY, cand.minY)
                edge = cand.maxX; cross = cand.minY
                reaches = cand.maxX <= frame.minX + 0.002
            case .right:
                overlap = min(frame.maxY, cand.maxY) - max(frame.minY, cand.minY)
                edge = -cand.minX; cross = cand.minY
                reaches = cand.minX >= frame.maxX - 0.002
            case .up:
                overlap = min(frame.maxX, cand.maxX) - max(frame.minX, cand.minX)
                edge = cand.maxY; cross = cand.minX
                reaches = cand.maxY <= frame.minY + 0.002
            case .down:
                overlap = min(frame.maxX, cand.maxX) - max(frame.minX, cand.minX)
                edge = -cand.minY; cross = cand.minX
                reaches = cand.minY >= frame.maxY - 0.002
            }
            guard overlap > 0, reaches else { continue }
            if let current = best, edge < current.edge || (edge == current.edge && cross >= current.cross) { continue }
            best = (id, edge, cross)
        }
        return best?.id
    }

    /// The split views that must survive an activation inside the same split.
    func retainedViews(forTabId id: UUID) -> [NSView] {
        let tabManager = controller.tabManager
        guard let split = tabManager.activeSplit, split.layout.paneIds.contains(id) else { return [] }
        let panes: [NSView] = split.layout.paneIds.compactMap { $0 == id ? nil : tabManager.loadedContentView(forTabId: $0) }
        return panes + Array(dividers.values) + Array(docks.values) + Array(handles.values) + [focusRing, marginView].compactMap { $0 }
    }

    /// Dividers and the margin share the window frame's color, fading together.
    func setFrameColor(_ color: NSColor, animated: Bool) {
        marginView?.setFrameColor(color, animated: animated)
        for divider in dividers.values { divider.setFrameColor(color, animated: animated) }
    }

    /// Pane (or divider) under the pointer. A press latches its target for the rest of the gesture
    /// and focuses the pane it lands in, so a drag that crosses a divider stays with its page.
    func view(for event: NSEvent) -> NSView? {
        // A peek covers every pane: a press on it must not activate the pane underneath, which would dismiss it.
        guard let split, case let container = controller.contentContainerView,
              !container.subviews.contains(where: { $0 is PagePeekView }) else { return nil }
        switch event.type {
        case .leftMouseDragged, .leftMouseUp, .rightMouseDragged, .rightMouseUp, .otherMouseDragged, .otherMouseUp:
            if let pointerTarget { return pointerTarget }
        default:
            break
        }
        let point = container.convert(event.locationInWindow, from: nil)
        let hoveredDivider = dividers.values.first { $0.frame.contains(point) }
        for divider in dividers.values { divider.setHovered(divider === hoveredDivider) }
        let tabManager = controller.tabManager
        let docks = docks
        var hit: (view: NSView, tabId: UUID?)?
        for (id, handle) in handles {
            if let target = handle.hitTest(point) { hit = (target, id); break }
        }
        hit = hit ?? hoveredDivider.map { ($0, nil) } ?? split.layout.paneIds.lazy.compactMap { id in
            guard let view = tabManager.loadedContentView(forTabId: id) else { return nil }
            if view.frame.contains(point) { return (view, id) }
            // The inspector docked beside the pane's page.
            return docks[id].flatMap { $0.frame.contains(point) ? ($0.hitTest(point) ?? $0, id) : nil }
        }.first
        guard let hit else { return nil }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            pointerTarget = hit.view
            if let tabId = hit.tabId, tabId != tabManager.activeOpenTabId { controller.activateTabStateFirst(id: tabId) }
        }
        return hit.view
    }

    /// The pointer monitor's every-move feed: reveals the handle whose strip holds the pointer and
    /// the divider under it. Nil (the pointer on the chrome) and any point off the panes hide them.
    func updateHover(atWindowPoint point: NSPoint?) {
        guard paneDragTabId == nil else {
            // A pane drag owns the pointer: no pill trails it across the panes.
            for handle in handles.values { handle.setRevealed(false) }
            return
        }
        guard split != nil else { return }
        let container = controller.contentContainerView
        guard let point, case let local = container.convert(point, from: nil), container.bounds.contains(local),
              !container.subviews.contains(where: { $0 is PagePeekView }) else {
            guard isHovering else { return }
            isHovering = false
            dividers.values.forEach { $0.setHovered(false) }
            handles.values.forEach { $0.setRevealed(false) }
            return
        }
        isHovering = true
        let hoveredDivider = dividers.values.first { $0.frame.contains(local) }
        for divider in dividers.values { divider.setHovered(divider === hoveredDivider) }
        for handle in handles.values { handle.setRevealed(handle.frame.contains(local)) }
    }

    /// The pane whose conversation surface claims `point` as a chrome zone, or nil. A conversation
    /// draws in the chrome web view and registers its whole pane as a `conversation-<tabId>` zone, so
    /// presses on the pane classify chrome and the tab is recovered through the zone id.
    private func conversationPaneTabId(atWindowPoint point: NSPoint) -> UUID? {
        guard let split,
              let zone = controller.chromeInteractiveZones.zoneId(
                  at: controller.chromeWebView.convert(point, from: nil),
                  in: controller.chromeWebView.bounds, isFlipped: controller.chromeWebView.isFlipped),
              zone.hasPrefix("conversation-"),
              let tabId = UUID(uuidString: String(zone.dropFirst("conversation-".count))),
              split.layout.paneIds.contains(tabId) else { return nil }
        return tabId
    }

    /// Click-to-focus for a conversation pane: its zone swallows the press before `view(for:)` can run.
    func activatePaneForChromePress(atWindowPoint point: NSPoint) {
        guard let tabId = conversationPaneTabId(atWindowPoint: point),
              tabId != controller.tabManager.activeOpenTabId else { return }
        controller.activateTabStateFirst(id: tabId)
    }

    /// A web link dragged from outside the pages over a narrow strip at a pane's left or right edge goes to the chrome, which
    /// offers it as a split pane; the rest of the pane, where a page's own fields and drop targets sit, keeps the drop.
    func isLinkDrag(_ sender: any NSDraggingInfo) -> Bool {
        let tabManager = controller.tabManager
        guard tabManager.activeTab != nil, case let container = controller.contentContainerView,
              (sender.draggingSource as? NSView)?.isDescendant(of: container) != true else { return false }
        let local = container.convert(sender.draggingLocation, from: nil)
        let paneFrames = split?.layout.paneIds.compactMap { tabManager.loadedContentView(forTabId: $0)?.frame } ?? []
        guard let pane = (paneFrames.isEmpty ? [container.bounds] : paneFrames).first(where: { $0.contains(local) }) else { return false }
        let band = min(pane.width / 6, 64)
        guard local.x < pane.minX + band || local.x > pane.maxX - band else { return false }
        if linkDragCache?.sequence != sender.draggingSequenceNumber {
            let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
            linkDragCache = (sender.draggingSequenceNumber, url?.scheme == "http" || url?.scheme == "https")
        }
        return linkDragCache?.isWebLink == true
    }
}

extension MainWindowController {
    /// Puts every pane of the active tab's split and its dividers on screen, or removes them when
    /// the active tab is not in a split.
    func layoutSplitContent() {
        guard let activeId = tabManager.activeOpenTabId,
              let activeView = tabManager.loadedContentView(forTabId: activeId) else { return }
        let split = tabManager.activeSplit
        let paneViews = split?.layout.paneIds.compactMap { id in id == activeId ? activeView : tabManager.contentView(forTabId: id) } ?? []
        guard let split, paneViews.count == split.layout.paneIds.count else {
            updateDisplayedTabs([activeId])
            guard splitPanes.split != nil else { return }
            splitPanes.clear()
            processOutgoingContentViews(contentContainerView.subviews.filter {
                $0 !== activeView && ($0 is WKWebView || $0 is TerminalView || $0 is ChangesView)
            })
            if let webView = activeView as? WKWebView, let engine = tabManager.engineTab(forWebView: webView) {
                engine.fitView(in: contentContainerView.bounds)
            } else {
                activeView.frame = contentContainerView.bounds
                activeView.autoresizingMask = [.width, .height]
            }
            if unsafe activeView.superview !== contentContainerView { contentContainerView.addSubview(activeView) }
            return
        }
        updateDisplayedTabs(Set(split.layout.paneIds))
        for id in split.layout.paneIds where id != activeId {
            guard let engine = tabManager.engineTab(for: id) else { continue }
            configureEngineIfNeeded(engine)
            engine.applyPageBackgroundColor(currentContentSurfaceColor)
        }
        // A pane that left the split leaves the screen with it.
        processOutgoingContentViews(contentContainerView.subviews.filter { view in
            (view is WKWebView || view is TerminalView || view is ChangesView) && !paneViews.contains { $0 === view }
        })
        // Frames first: a pane joining the window at another size would size its shell and draw a
        // frame for it.
        splitPanes.show(split)
        for view in paneViews {
            if unsafe view.superview !== contentContainerView { splitPanes.addPane(view) }
            view.isHidden = false
        }
    }

    /// Splits the active tab with a new blank tab that opens the command bar.
    func splitActiveTabWithNewTab() {
        guard let spaceId = tabManager.currentSpaceId, let activeId = tabManager.activeOpenTabId else { return }
        let previous = tabManager.activeSplit
        guard (previous?.layout.paneIds.count ?? 0) < SplitLayout.maxPanes else { return NSSound.beep() }
        var created: [UUID] = []
        guard let keptId = splitPane(for: activeId, created: &created),
              let tab = createTabStateFirst(url: nil, activate: true) else { return }
        created.append(tab.id)
        guard (try? applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: tab.id, targetTabId: keptId, vertical: false, before: false))) != nil else {
            for id in created { closeTabStateFirst(id: id, undoable: false) }
            return
        }
        bridgeRouter.send(event: "openCommandBar", data: ["newTab": true])
        registerSplitUndo(previous: previous, activeId: activeId, createdTabIds: created)
    }

    /// Puts `tabId` beside the chosen tab (or the active tab when no target is given).
    /// A pane of the same split moves there.
    func splitTab(_ tabId: UUID, at targetId: UUID?, vertical: Bool, before: Bool, createdTabIds: [UUID] = []) {
        guard let spaceId = tabManager.currentSpaceId, let activeId = tabManager.activeOpenTabId else { return }
        let anchor = targetId ?? activeId
        var created = createdTabIds
        var didSplit = false
        defer {
            if !didSplit {
                for id in created { closeTabStateFirst(id: id, undoable: false) }
            }
        }
        guard tabId != anchor, let spaceTab = context.browserState.space(id: spaceId)?.spaceTab,
              spaceTab.storedTab(anchor) != nil, let target = splitPane(for: anchor, created: &created) else { return }
        let previous = spaceTab.splitGroup(containing: anchor)
        do {
            let changes = try applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: tabId, targetTabId: target, vertical: vertical, before: before))
            // A full split refuses a new pane.
            guard let state = changes.changedState, let groupId = state.tabsById[tabId]?.groupId,
                  groupId == state.tabsById[target]?.groupId else { return }
            didSplit = true
            activateTabStateFirst(id: tabId)
            registerSplitUndo(previous: previous, activeId: activeId, createdTabIds: created)
        } catch {
            Self.logger.error("split failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Puts `tabId` in the place of the `targetId` pane, which goes back to the list; two panes of
    /// the split trade places.
    func replaceSplitPane(_ targetId: UUID, with tabId: UUID, createdTabIds: [UUID] = []) {
        guard let spaceId = tabManager.currentSpaceId, let activeId = tabManager.activeOpenTabId,
              let previous = tabManager.activeSplit, previous.layout.paneIds.contains(targetId) else { return }
        do {
            _ = try applyBrowserCommand(.replaceSplitPane(spaceId: spaceId, targetTabId: targetId, tabId: tabId))
            activateTabStateFirst(id: tabId)
            registerSplitUndo(previous: previous, activeId: activeId, createdTabIds: createdTabIds)
        } catch {
            Self.logger.error("split replace failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The tab that joins a split on behalf of `tabId`: itself, or for a bookmark, which keeps its
    /// place in the grid, a fresh tab on the bookmark's current page.
    private func splitPane(for tabId: UUID, created: inout [UUID]) -> UUID? {
        guard let tab = tabManager.tab(for: tabId) else { return nil }
        guard tab.isBookmarked else { return tabId }
        guard let copy = createTabStateFirst(url: tab.url, activate: false) else { return nil }
        created.append(copy.id)
        return copy.id
    }

    /// Edit > Undo (Cmd+Z) takes the split back to `previous`: panes that joined go back to the
    /// list, panes that left return, the arrangement is restored, the tabs opened for it close and
    /// the tab that was active before is active again. Without a previous split, the split goes.
    func registerSplitUndo(previous: SplitGroup?, activeId: UUID, createdTabIds: [UUID]) {
        guard let undoManager = window?.undoManager else { return }
        let currentFolderId = tabManager.activeSplit?.folderId
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                guard let spaceId = controller.tabManager.currentSpaceId,
                      let space = controller.context.browserState.space(id: spaceId) else { return }
                if let previous {
                    let now = space.spaceTab.folder(id: previous.folderId)?.splitLayout?.paneIds ?? []
                    for id in now where !previous.layout.paneIds.contains(id) {
                        let section: TabTreeItem.Section = controller.tabManager.tab(for: id)?.isPinned == true ? .pinned : .unpinned
                        _ = try? controller.applyBrowserCommand(.moveSidebarItem(
                            spaceId: spaceId, kind: .tab, itemId: id, parentFolderId: nil, section: section,
                            insert: .anchored(fallbackIndex: .max, insertBeforeId: nil, insertAfterId: previous.folderId)
                        ))
                    }
                    for id in previous.layout.paneIds where !now.contains(id) {
                        guard let anchor = controller.context.browserState.space(id: spaceId)?.spaceTab
                            .folder(id: previous.folderId)?.splitLayout?.paneIds.first else { break }
                        _ = try? controller.applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: id, targetTabId: anchor, vertical: false, before: false))
                    }
                    _ = try? controller.applyBrowserCommand(.setSplitLayout(spaceId: spaceId, folderId: previous.folderId, layout: previous.layout))
                } else if let currentFolderId, controller.tabManager.folder(id: currentFolderId) != nil {
                    _ = try? controller.applyBrowserCommand(.deleteFolder(spaceId: spaceId, folderId: currentFolderId))
                }
                controller.activateTabStateFirst(id: activeId)
                for id in createdTabIds { controller.closeTabStateFirst(id: id, undoable: false) }
                controller.layoutSplitContent()
            }
        }
        undoManager.setActionName("Split View".localized)
    }

    /// A link dropped on a pane's edge, or on a pane of a full split, which it then replaces.
    func splitURL(_ url: URL, at targetId: UUID?, side: SplitDropSide) {
        guard let tab = createTabStateFirst(url: url, activate: false) else { return }
        dropTab(tab.id, at: targetId, side: side, createdTabIds: [tab.id])
    }

    func dropTab(_ tabId: UUID, at targetId: UUID?, side: SplitDropSide, createdTabIds: [UUID] = []) {
        switch side {
        case .replace:
            guard let targetId else { return }
            replaceSplitPane(targetId, with: tabId, createdTabIds: createdTabIds)
        case let .edge(vertical, before):
            splitTab(tabId, at: targetId, vertical: vertical, before: before, createdTabIds: createdTabIds)
        }
    }

    @objc func newSplitView(_ sender: Any?) { splitActiveTabWithNewTab() }

    @objc func newTerminalBeside(_ sender: Any?) { splitWithNewTerminal(vertical: false) }
    @objc func newTerminalBelow(_ sender: Any?) { splitWithNewTerminal(vertical: true) }

    /// Cuts the focused pane, page or terminal, with a new terminal beside it or below it, in the
    /// directory the tab is about.
    func splitWithNewTerminal(vertical: Bool) {
        guard context.settingsStore?.terminalEnabled != false, let spaceId = tabManager.currentSpaceId, let id = tabManager.activeOpenTabId else { return }
        let previous = tabManager.activeSplit
        guard (previous?.layout.paneIds.count ?? 0) < SplitLayout.maxPanes else { return NSSound.beep() }
        var created: [UUID] = []
        guard let keptId = splitPane(for: id, created: &created), let terminal = createTerminalTab(activate: false) else { return }
        created.append(terminal.id)
        guard (try? applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: terminal.id, targetTabId: keptId, vertical: vertical, before: false))) != nil else {
            for id in created { closeTabStateFirst(id: id, undoable: false) }
            return
        }
        activateTabStateFirst(id: terminal.id)
        registerSplitUndo(previous: previous, activeId: id, createdTabIds: created)
    }

    @objc func closeSplitView(_ sender: Any?) {
        guard let spaceId = tabManager.currentSpaceId, let split = tabManager.activeSplit else { return }
        _ = try? applyBrowserCommand(.deleteFolder(spaceId: spaceId, folderId: split.folderId))
    }

    /// Takes `tabId` out of its split, back into the list just after it; the tab stays open.
    func unsplitTab(_ tabId: UUID) {
        guard let spaceId = tabManager.context(for: tabId)?.spaceId ?? tabManager.currentSpaceId else { return }
        // The shown split follows the active tab: the pane beside the leaving one takes the focus
        // first, so the rest of the split stays on screen.
        if tabId == tabManager.activeOpenTabId, let paneIds = tabManager.activeSplit?.layout.paneIds,
           let index = paneIds.firstIndex(of: tabId) {
            let rest = paneIds.filter { $0 != tabId }
            activateTabStateFirst(id: rest[min(index, rest.count - 1)])
        }
        _ = try? applyBrowserCommand(.unsplitTab(spaceId: spaceId, tabId: tabId))
    }

    /// Leaves `tabId` alone on the page: the split dissolves and its other panes rejoin the list.
    func maximizeSplitPane(_ tabId: UUID) {
        guard let spaceId = tabManager.context(for: tabId)?.spaceId ?? tabManager.currentSpaceId,
              let split = tabManager.activeSplit, split.layout.paneIds.contains(tabId) else { return }
        if tabId != tabManager.activeOpenTabId { activateTabStateFirst(id: tabId) }
        _ = try? applyBrowserCommand(.deleteFolder(spaceId: spaceId, folderId: split.folderId))
    }

    @objc func closeActiveSplitPane(_ sender: Any?) {
        guard let id = tabManager.activeOpenTabId else { return }
        unsplitTab(id)
    }

    @objc func maximizeActiveSplitPane(_ sender: Any?) {
        guard let id = tabManager.activeOpenTabId else { return }
        maximizeSplitPane(id)
    }

    /// Trades the focused pane's place with the pane on `direction`'s side: the menu's
    /// keyboard alternative to dragging the pane onto another's edge or center.
    @objc func moveSplitPane(_ sender: NSMenuItem) {
        guard let id = tabManager.activeOpenTabId,
              let direction = SplitPaneDirection(rawValue: sender.tag) else { return }
        guard let target = SplitPanesController.neighborPane(of: id, in: splitPanes.sentPaneFrames, direction: direction)
        else { return NSSound.beep() }
        replaceSplitPane(target, with: id)
    }
}

/// A pane move's direction, as the menu item's tag carries it.
enum SplitPaneDirection: Int {
    case left, right, up, down
}

/// Where a tab dropped on the page lands: on one edge of a pane, or in its place.
enum SplitDropSide {
    case edge(vertical: Bool, before: Bool)
    case replace

    /// The chrome's drop zone names: left, right, top, bottom or replace.
    init?(_ name: String?) {
        switch name {
        case "left": self = .edge(vertical: false, before: true)
        case "right": self = .edge(vertical: false, before: false)
        case "top": self = .edge(vertical: true, before: true)
        case "bottom": self = .edge(vertical: true, before: false)
        case "replace": self = .replace
        default: return nil
        }
    }
}
