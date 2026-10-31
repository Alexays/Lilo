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
        let scale = window?.backingScaleFactor ?? 2
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

    func setFrameColor(_ color: NSColor, animated: Bool) {
        guard color != frameColor else { return }
        frameColor = color
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(WindowFrameView.colorFadeDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.backgroundColor = color.cgColor
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
        guard let superview else { return }
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
    /// The layout while a divider is being dragged; persisted on the split folder on release.
    private var liveLayout: SplitLayout?
    /// Pane frames last sent to the chrome, as shares of the content area.
    var sentPaneFrames: [UUID: NSRect] = [:]
    private var focusRing: SplitFocusRingView?
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
        split = nil
        liveLayout = nil
        dividers.values.forEach { $0.removeFromSuperview() }
        dividers = [:]
        focusRing?.removeFromSuperview()
        sendPaneFrames([:])
    }

    private func makeDivider(path: [Bool]) -> SplitDividerView {
        let divider = SplitDividerView()
        divider.setFrameColor(controller.window?.backgroundColor ?? MainWindowController.defaultSidebarBackgroundColor(), animated: false)
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

    /// How short a part can get along a cut's axis: its panes' minimum, plus the dividers between
    /// panes stacked along that same axis.
    private static func minimumLength(of layout: SplitLayout, vertical: Bool) -> CGFloat {
        guard case let .split(isVertical, _, first, second) = layout else { return minimumPaneLength }
        let firstLength = minimumLength(of: first, vertical: vertical)
        let secondLength = minimumLength(of: second, vertical: vertical)
        return isVertical == vertical ? firstLength + SplitDividerView.width + secondLength : max(firstLength, secondLength)
    }

    /// Each pane's frame and each cut's divider frame and bounds, in the container's coordinates.
    private func frames(
        _ layout: SplitLayout, in rect: NSRect, path: [Bool],
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
            let flipped = controller.contentContainerView.isFlipped
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
        frames(first, in: firstRect, path: path + [false], panes: &panes, cuts: &cuts)
        frames(second, in: secondRect, path: path + [true], panes: &panes, cuts: &cuts)
    }

    func applyFrames(animatesFocus: Bool = true) {
        guard let split else { return }
        let tabManager = controller.tabManager
        let container: NSView = controller.contentContainerView
        var panes: [UUID: NSRect] = [:]
        var cuts: [[Bool]: (divider: NSRect, bounds: NSRect, vertical: Bool)] = [:]
        frames(liveLayout ?? split.layout, in: container.bounds, path: [], panes: &panes, cuts: &cuts)
        for (tabId, frame) in panes {
            guard let view = tabManager.loadedContentView(forTabId: tabId) else { continue }
            view.autoresizingMask = []
            view.frame = frame
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
            if divider.superview !== container {
                container.addSubview(divider, positioned: .below, relativeTo: focusRing)
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

    /// The split views that must survive an activation inside the same split.
    func retainedViews(forTabId id: UUID) -> [NSView] {
        let tabManager = controller.tabManager
        guard let split = tabManager.activeSplit, split.layout.paneIds.contains(id) else { return [] }
        let panes: [NSView] = split.layout.paneIds.compactMap { $0 == id ? nil : tabManager.loadedContentView(forTabId: $0) }
        return panes + Array(dividers.values) + [focusRing].compactMap { $0 }
    }

    /// Pane (or divider) under the pointer. A press latches its target for the rest of the gesture
    /// and focuses the pane it lands in, so a drag that crosses a divider stays with its page.
    func view(for event: NSEvent) -> NSView? {
        // A peek covers every pane: a press on it must not activate the pane underneath, which would dismiss it.
        guard let split, let container = controller.contentContainerView,
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
        let hit: (view: NSView, tabId: UUID?)? = hoveredDivider.map { ($0, nil) } ?? split.layout.paneIds.lazy.compactMap { id in
            tabManager.loadedContentView(forTabId: id).flatMap { $0.frame.contains(point) ? ($0, id) : nil }
        }.first
        guard let hit else { return nil }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            pointerTarget = hit.view
            if let tabId = hit.tabId, tabId != tabManager.activeOpenTabId { controller.activateTabStateFirst(id: tabId) }
        }
        return hit.view
    }

    /// A web link dragged from outside the pages over a narrow strip at a pane's left or right edge goes to the chrome, which
    /// offers it as a split pane; the rest of the pane, where a page's own fields and drop targets sit, keeps the drop.
    func isLinkDrag(_ sender: any NSDraggingInfo) -> Bool {
        let tabManager = controller.tabManager
        guard tabManager.activeTab != nil, let container = controller.contentContainerView,
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
            if activeView.superview !== contentContainerView { contentContainerView.addSubview(activeView) }
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
        // frame for it. Joining panes go to the back, under the dividers and the focus ring.
        splitPanes.show(split)
        for view in paneViews {
            if view.superview !== contentContainerView { contentContainerView.addSubview(view, positioned: .below, relativeTo: nil) }
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

    /// Cuts the `targetId` pane in two for `tabId`, on the left or top half when `before`. Without
    /// a split on screen the active tab is the target. A pane of the same split moves there.
    func splitTab(_ tabId: UUID, at targetId: UUID?, vertical: Bool, before: Bool, createdTabIds: [UUID] = []) {
        guard let spaceId = tabManager.currentSpaceId, let activeId = tabManager.activeOpenTabId else { return }
        var created = createdTabIds
        let previous = tabManager.activeSplit
        let target: UUID
        if let previous {
            // A stale target (the split changed under the drag) falls back to the focused pane.
            target = targetId.flatMap { previous.layout.paneIds.contains($0) ? $0 : nil } ?? activeId
        } else {
            guard tabId != activeId, let pane = splitPane(for: activeId, created: &created) else { return }
            target = pane
        }
        guard tabId != target else { return }
        do {
            let changes = try applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: tabId, targetTabId: target, vertical: vertical, before: before))
            // A full split refuses a new pane.
            guard let state = changes.changedState, state.tabsById[tabId]?.groupId == state.tabsById[target]?.groupId else {
                for id in created { closeTabStateFirst(id: id, undoable: false) }
                return
            }
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
