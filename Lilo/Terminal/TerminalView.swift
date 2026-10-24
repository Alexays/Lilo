import AppKit
import Carbon
import Metal
import QuartzCore
import os
import Synchronization

/// Shows a `TerminalSession`. Rendering happens on a dedicated thread driven by the view's display
/// link, which only runs while something changes; `TerminalHost` wakes it on output. Call
/// `shutdown()` before dropping it.
@MainActor
final class TerminalView: NSView {
    /// Padding around the grid, in points.
    static let padding = CGSize(width: 10, height: 8)

    let session: TerminalSession
    /// Opens a link the user Command-clicked; web links and files alike.
    var onOpenURL: ((URL) -> Void)?
    let renderLoop: TerminalRenderLoop
    private(set) var font: TerminalFont?
    private(set) var fontScale: CGFloat = 0
    private(set) var grid = (cols: 0, rows: 0)

    // Input state, used by TerminalView+Input.swift.
    let input = VTInputEncoder()
    let selectionGesture = VTSelectionGesture()
    var markedText = NSAttributedString()
    var typedText: [String]?
    var reportingMouse = false
    var optionAsMeta = TerminalHost.OptionAsMeta.off
    var hoveredLink: TerminalLink?
    /// The cell last looked up for a Command-hovered link, nil without Command.
    var probedLinkCell: (x: Int, y: Int)?
    /// Rows of the command bar under the pointer, which a click selects the output of.
    var hoveredMarkRows: ClosedRange<Int>?
    /// Where a Command-hovered link goes, shown at the bottom left like a browser's status bar.
    lazy var linkLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.drawsBackground = true
        label.backgroundColor = .windowBackgroundColor
        label.lineBreakMode = .byTruncatingMiddle
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.isHidden = true
        addSubview(label)
        return label
    }()
    var scrollRemainder: CGFloat = 0
    let searchState = TerminalSearchState()
    static let searchQueue = DispatchQueue(label: "fr.arouillard.lilo.terminal.search", qos: .userInitiated)
    let preeditLabel = NSTextField(labelWithString: "")

    private let metalLayer = CAMetalLayer()
    private var fontFamily: String?
    private var fontSize: CGFloat
    /// This tab's own zoom, in points over the size from the settings.
    private(set) var zoom: CGFloat = 0
    private var windowObservers: [NSObjectProtocol] = []
    private var hasFocus = false
    private var secureInput = false
    private lazy var secureInputBadge: NSImageView = {
        let badge = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure keyboard entry".localized) ?? NSImage())
        badge.contentTintColor = .secondaryLabelColor
        badge.toolTip = "Secure keyboard entry: other apps cannot read what you type.".localized
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        badge.frame = NSRect(x: bounds.width - 26, y: bounds.height - 24, width: 16, height: 16)
        addSubview(badge)
        return badge
    }()

    /// The shell is reading a password: while this terminal has focus, no other app sees the keys.
    var readsPassword = false {
        didSet { updateSecureInput() }
    }

    init?(session: TerminalSession, fontFamily: String? = nil, fontSize: CGFloat = 13) {
        guard let renderer = TerminalRenderer() else { return nil }
        self.session = session
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        renderLoop = TerminalRenderLoop(session: session, renderer: renderer, layer: metalLayer, searchState: searchState)
        super.init(frame: .zero)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = TerminalRenderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        wantsLayer = true
        // A frame drawn for another size (a live resize, a pane between two layouts) stays pinned to
        // the top left instead of stretched. AppKit sets the layer's gravity from this, not the reverse.
        layerContentsPlacement = .topLeft
        layerContentsRedrawPolicy = .never
        preeditLabel.isHidden = true
        addSubview(preeditLabel)
        registerForDraggedTypes([.fileURL, .URL, .string])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal".localized)
    }

    /// The rows in view, read when VoiceOver asks: nothing follows the output in between.
    override func accessibilityValue() -> Any? {
        session.withLockedTerminal { $0.viewportText } ?? ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    /// Leaves `session.onOutput` in place: the parse thread may be reading it right now, and waking
    /// a stopped render loop does nothing.
    func shutdown() {
        readsPassword = false
        renderLoop.shutdown()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        setFocus(window?.isKeyWindow == true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setFocus(false)
        return true
    }

    /// Focus means first responder in the key window: a blinking cursor or a focus report while
    /// the user is in another app would be wrong (and a wasted wake every blink).
    private func setFocus(_ focused: Bool) {
        guard focused != hasFocus else { return }
        hasFocus = focused
        renderLoop.setFocused(focused)
        session.reportFocus(focused)
        updateSecureInput()
    }

    /// Secure event input is system-wide and counted: every enable is paired with one disable.
    private func updateSecureInput() {
        let wanted = readsPassword && hasFocus
        guard wanted != secureInput else { return }
        secureInput = wanted
        if wanted { EnableSecureEventInput() } else { DisableSecureEventInput() }
        secureInputBadge.isHidden = !wanted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let window else {
            setFocus(false)
            renderLoop.setVisible(false, releaseResources: true)
            // Resizing frees the layer's full-size drawables; updateGrid restores the size on return.
            metalLayer.drawableSize = CGSize(width: 1, height: 1)
            return
        }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setFocus(self.window?.isKeyWindow == true && self.window?.firstResponder === self)
                }
            })
        }
        renderLoop.attach(displayLink: displayLink(target: renderLoop, selector: #selector(TerminalRenderLoop.step(_:))))
        updateFont()
        updateGrid()
        updateVisibility()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateFont()
    }

    override func layout() {
        super.layout()
        updateGrid()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateGrid(force: true)
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibility()
    }

    private func updateVisibility() {
        guard let window else { return }
        renderLoop.setVisible(window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor, releaseResources: false)
    }

    /// Applies a new font live; the grid is recomputed and the shell told its new size.
    func setFont(family: String?, size: CGFloat) {
        guard family != fontFamily || size != fontSize else { return }
        fontFamily = family
        fontSize = size
        fontScale = 0
        if window != nil { updateFont() }
    }

    /// Zooms this terminal only; `nil` goes back to the size from the settings. Returns the zoom
    /// level relative to that size.
    @discardableResult
    func setZoom(by delta: CGFloat?) -> Double {
        let zoom = delta.map { min(max(self.zoom + $0, 6 - fontSize), 72 - fontSize) } ?? 0
        if zoom != self.zoom {
            self.zoom = zoom
            fontScale = 0
            if window != nil { updateFont() }
        }
        return Double((fontSize + zoom) / fontSize)
    }

    private func updateFont() {
        let scale = window?.backingScaleFactor ?? 2
        guard scale != fontScale else { return }
        fontScale = scale
        metalLayer.contentsScale = scale
        let font = TerminalFont(family: fontFamily, pointSize: fontSize + zoom, scale: scale)
        self.font = font
        renderLoop.setFont(font, padding: SIMD2(Float(Self.padding.width * scale), Float(Self.padding.height * scale)))
        grid = (0, 0)
        updateGrid(force: true)
    }

    private func updateGrid(force: Bool = false) {
        // A view added with an empty frame (a split pane) would otherwise tell the shell it is 2x1.
        guard let font, fontScale > 0, bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: bounds.width * fontScale, height: bounds.height * fontScale)
        if metalLayer.drawableSize != size, size.width > 0, size.height > 0 {
            metalLayer.drawableSize = size
            renderLoop.setNeedsFrame()
        }
        let cols = max(2, Int((size.width - 2 * Self.padding.width * fontScale) / CGFloat(font.cellWidth)))
        let rows = max(1, Int((size.height - 2 * Self.padding.height * fontScale) / CGFloat(font.cellHeight)))
        guard cols != grid.cols || rows != grid.rows || force else { return }
        // A live resize reflows the shell once, at the end, instead of on every intermediate size.
        guard !inLiveResize else { return }
        grid = (cols, rows)
        session.resize(cols: UInt16(cols), rows: UInt16(rows), cellWidth: UInt32(font.cellWidth), cellHeight: UInt32(font.cellHeight))
        renderLoop.setNeedsFrame()
    }
}

/// The render thread: owns the render state and frame builder, and draws when the display link
/// fires. Every method called from the main thread hops onto this thread's run loop.
final class TerminalRenderLoop: NSObject, @unchecked Sendable {
    private static let slideDuration = 0.06
    private static let blinkInterval = 0.6
    /// As in kitty, the cursor stops blinking this long after it last moved: an idle prompt then
    /// costs no frames.
    private static let blinkDuration = 15.0
    /// How long a hidden terminal keeps its shaped runs, and one out of its window its glyph atlas
    /// too: tab switches usually come back well within it.
    private static let releaseDelay: TimeInterval = 180

    private let session: TerminalSession
    private let renderer: TerminalRenderer
    private let layer: CAMetalLayer
    private let searchState: TerminalSearchState
    private let renderState = VTRenderState()
    private let wakePending = Atomic<Bool>(false)
    /// The terminal or what is drawn over it may have changed since the last update; a frame
    /// without it (a cursor blink) skips the terminal lock and the GPU copies.
    private let needsUpdate = Atomic<Bool>(true)
    /// `visible` as the parse thread sees it, set before the render thread's copy.
    private let onScreen = Atomic<Bool>(false)
    private var runLoop: CFRunLoop?
    private let stopped = Atomic<Bool>(false)

    // Render-thread state.
    private var link: CADisplayLink?
    private var font: TerminalFont?
    private var builder: TerminalFrameBuilder?
    private var padding = SIMD2<Float>.zero
    private var scrollOffset: Float = 0
    private var lastScroll: CFTimeInterval = 0
    private var highlightColors: (selection: VTColor, match: VTColor, marks: (success: VTColor, failure: VTColor))?
    private var hoveredLink: TerminalLink?
    private var hoveredMarkRow: Int?
    private var visible = false
    private var focused = false
    private var needsFrame = true
    private var lastFrameTime: CFTimeInterval = 0
    private var lastChange: CFTimeInterval = 0
    private var cursorTarget = SIMD2<Float>(-1, -1)
    private var slideFrom = SIMD2<Float>.zero
    private var slideStart: CFTimeInterval = 0
    private var blinkStart: CFTimeInterval = 0
    private var blinkTimer: Timer?
    private var releaseTimer: Timer?
    /// The builder's content changed since the last frame handed to the renderer.
    private var contentChanged = true

    init(session: TerminalSession, renderer: TerminalRenderer, layer: CAMetalLayer, searchState: TerminalSearchState) {
        self.session = session
        self.renderer = renderer
        self.layer = layer
        self.searchState = searchState
        super.init()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // The port keeps the run loop alive while the display link is paused or detached.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while !stopped.load(ordering: .acquiring) { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "lilo.terminal.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func attach(displayLink: CADisplayLink) {
        perform { [self] in
            link?.invalidate()
            displayLink.add(to: .current, forMode: .default)
            displayLink.isPaused = !needsFrame
            link = displayLink
        }
    }

    func setFont(_ font: TerminalFont, padding: SIMD2<Float>) {
        perform { [self] in
            self.font = font
            self.padding = padding
            builder = nil
            requestFrame()
        }
    }

    func setVisible(_ visible: Bool, releaseResources: Bool) {
        onScreen.store(visible, ordering: .releasing)
        session.inBackground.store(!visible, ordering: .relaxed)
        perform { [self] in
            self.visible = visible
            updatePriority()
            releaseTimer?.invalidate()
            releaseTimer = nil
            if !visible {
                // Hidden in its window (occluded), the atlas stays: coming back costs no rasterizing.
                let timer = Timer(timeInterval: Self.releaseDelay, repeats: false) { [weak self] _ in
                    if releaseResources { self?.builder = nil } else { self?.builder?.shaper.cache = [:] }
                }
                timer.tolerance = 30
                RunLoop.current.add(timer, forMode: .default)
                releaseTimer = timer
            }
            if visible { requestFrame() } else { link?.isPaused = true }
        }
    }

    func setFocused(_ focused: Bool) {
        perform { [self] in
            self.focused = focused
            updatePriority()
            blinkStart = CACurrentMediaTime()
            requestFrame()
        }
    }

    func setNeedsFrame() {
        perform { [self] in requestFrame() }
    }

    /// The trackpad's sub-row offset, in pixels. Set and read only under the terminal lock, together
    /// with the viewport row it belongs to: set apart, a frame could pair the new row with the old
    /// offset and jump a line.
    var lockedScrollOffset: Float = 0

    /// Draws the next frames at up to 120 Hz while the content moves under the fingers.
    func scrolled() {
        perform { [self] in
            lastScroll = CACurrentMediaTime()
            requestFrame()
        }
    }

    func setHoveredMarkRow(_ row: Int?) {
        perform { [self] in
            hoveredMarkRow = row
            requestFrame()
        }
    }

    func setLink(_ link: TerminalLink?) {
        perform { [self] in
            hoveredLink = link
            builder?.link = link
            requestFrame()
        }
    }

    func setHighlightColors(selection: VTColor, match: VTColor, marks: (success: VTColor, failure: VTColor)) {
        perform { [self] in
            highlightColors = (selection, match, marks)
            builder?.selectionBackground = selection
            builder?.matchBackground = match
            builder?.markColors = marks
            requestFrame()
        }
    }

    /// Called on the parse thread after each batch of output. A hidden terminal keeps parsing but
    /// costs no frames, nor a render-thread wakeup; showing it again draws once.
    func wake() {
        needsUpdate.store(true, ordering: .releasing)
        guard onScreen.load(ordering: .acquiring), !wakePending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        perform { [self] in
            // Hidden between the check above and now.
            guard visible else {
                wakePending.store(false, ordering: .releasing)
                needsFrame = true
                return
            }
            // Nothing drawn for a whole refresh interval: draw now rather than on the next vsync,
            // which is what keeps typing latency low. Output nobody types into waits for 30 Hz.
            let interval = focused ? link?.duration ?? 1.0 / 60 : 1.0 / 30
            if CACurrentMediaTime() - lastFrameTime > interval { renderFrame() }
            link?.isPaused = false
        }
    }

    func shutdown() {
        perform { [self] in
            link?.invalidate()
            link = nil
            blinkTimer?.invalidate()
            releaseTimer?.invalidate()
            stopped.store(true, ordering: .releasing)
            // A performed block does not end `run(mode:before:)`: without this, the thread and
            // everything it holds (session, glyph atlas) would outlive the terminal.
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    @objc func step(_ link: CADisplayLink) {
        renderFrame()
    }

    /// Typing in front gets the fastest scheduling; a hidden terminal only parses, so its render
    /// thread steps down to background-friendly cores.
    private func updatePriority() {
        let qos = focused && visible ? QOS_CLASS_USER_INTERACTIVE : visible ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY
        pthread_set_qos_class_self_np(qos, 0)
    }

    private func requestFrame() {
        needsUpdate.store(true, ordering: .relaxed)
        needsFrame = true
        link?.isPaused = !visible
    }

    private func renderFrame() {
        wakePending.store(false, ordering: .releasing)
        guard visible, let font else {
            link?.isPaused = true
            return
        }
        let fresh = self.builder == nil
        let builder = self.builder ?? TerminalFrameBuilder(font: font, atlas: GlyphAtlas(device: renderer.device))
        if fresh {
            if let highlightColors {
                builder.selectionBackground = highlightColors.selection
                builder.matchBackground = highlightColors.match
                builder.markColors = highlightColors.marks
            }
            builder.link = hoveredLink
            let renderer = renderer
            builder.atlas.willReset = { renderer.waitUntilIdle() }
            self.builder = builder
            contentChanged = true
        }
        var changed = false
        if needsUpdate.exchange(false, ordering: .acquiringAndReleasing) || fresh {
            var highlights: [(row: Int, columns: ClosedRange<Int>)]?
            var marks: [TerminalCommandMark] = []
            session.withLockedTerminal { terminal in
                renderState.beginUpdate(from: terminal)
                highlights = searchState.viewportMatches(terminal: terminal)
                marks = terminal.visibleCommandMarks()
                scrollOffset = lockedScrollOffset
            }
            renderState.endUpdate()
            changed = builder.update(from: renderState, highlights: highlights)
            // Bars sit in the left padding: a third of it in from the window edge.
            let markWidth = max(2, Int(padding.x / 5))
            if builder.updateCommandMarks(marks, hoveredRow: hoveredMarkRow, x: -Int(padding.x * 2 / 3), width: markWidth) { changed = true }
            renderState.clean()
        }

        let now = CACurrentMediaTime()
        if changed {
            lastChange = now
            contentChanged = true
        }
        let (uniforms, animating) = makeUniforms(builder: builder, font: font, now: now)
        if changed || animating || needsFrame {
            if let drawable = layer.nextDrawable() {
                renderer.render(builder, uniforms: uniforms, into: drawable.texture, present: drawable, contentChanged: contentChanged)
                contentChanged = false
                lastFrameTime = now
                needsFrame = false
            } else {
                // The builder already consumed this change; keep the link running until it is shown.
                needsFrame = true
            }
        }
        // ProMotion for the cursor's glide and scrolling, 60 Hz for fresh output where the user types;
        // background output (an agent's spinner) gets 30 Hz.
        let rate = now - slideStart < Self.slideDuration || now - lastScroll < 0.25
            ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            : focused && now - lastChange < 0.25
            ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            : CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        if link?.preferredFrameRateRange != rate { link?.preferredFrameRateRange = rate }
        if !animating, !needsFrame {
            link?.isPaused = true
            scheduleBlink(builder: builder, now: now)
        }
    }

    /// Uniforms for this frame, and whether the cursor is mid-slide.
    private func makeUniforms(builder: TerminalFrameBuilder, font: TerminalFont, now: CFTimeInterval) -> (TerminalUniforms, Bool) {
        func rgba(_ color: VTColor) -> SIMD4<Float> {
            SIMD4(Float(color.r) / 255, Float(color.g) / 255, Float(color.b) / 255, 1)
        }
        var uniforms = TerminalUniforms()
        uniforms.viewport = SIMD2(Float(layer.drawableSize.width), Float(layer.drawableSize.height))
        uniforms.cellSize = SIMD2(Float(font.cellWidth), Float(font.cellHeight))
        uniforms.padding = padding
        uniforms.grid = SIMD2(UInt32(builder.cols), UInt32(builder.rows))
        uniforms.background = rgba(builder.defaultBackground)
        uniforms.scrollOffset = scrollOffset
        guard let cursor = builder.cursor, cursor.visible else { return (uniforms, false) }

        // The glide follows the cursor's own moves; scrolling carries it along with the text at once.
        let target = padding + SIMD2(Float(cursor.x), Float(cursor.y)) * uniforms.cellSize
        if target != cursorTarget {
            // Short hops (typing) glide; jumps across rows land at once.
            let glides = cursorTarget.x >= 0 && abs(target.y - cursorTarget.y) < 0.5 && abs(target.x - cursorTarget.x) <= uniforms.cellSize.x * 4
            slideFrom = glides ? currentCursorOrigin(now: now) : target
            slideStart = now
            cursorTarget = target
            blinkStart = now
        }
        let sliding = now - slideStart < Self.slideDuration
        let origin = currentCursorOrigin(now: now) + SIMD2(0, scrollOffset)

        // A hard blink: odd phases hide the cursor, so each phase costs one frame.
        let elapsed = now - blinkStart
        let alpha: Float = focused && cursor.blinking && elapsed < Self.blinkDuration && Int(elapsed / Self.blinkInterval) % 2 == 1 ? 0 : 1

        let style = focused ? cursor.style : .hollow
        let cell = uniforms.cellSize
        let thickness = Float(max(2, font.lineThickness))
        var size = cell
        switch style {
        case .bar: size.x = thickness
        case .underline: size.y = thickness
        case .block, .hollow: break
        }
        let top = style == .underline ? origin.y + cell.y - thickness : origin.y
        uniforms.cursorRect = SIMD4(origin.x, top, size.x, size.y)
        uniforms.cursorColor = rgba(builder.cursorColor ?? builder.defaultForeground)
        uniforms.cursorTextColor = rgba(builder.defaultBackground)
        uniforms.cursorAlpha = alpha
        uniforms.cursorStyle = switch style {
        case .block: 0
        case .bar: 1
        case .underline: 2
        case .hollow: 3
        }
        return (uniforms, sliding)
    }

    private func currentCursorOrigin(now: CFTimeInterval) -> SIMD2<Float> {
        let slide = min(1, (now - slideStart) / Self.slideDuration)
        return slideFrom + (cursorTarget - slideFrom) * Float(1 - pow(1 - slide, 3))
    }

    /// While the screen is idle the display link is paused; a timer wakes it for the next blink phase.
    private func scheduleBlink(builder: TerminalFrameBuilder, now: CFTimeInterval) {
        blinkTimer?.invalidate()
        blinkTimer = nil
        let elapsed = now - blinkStart
        guard visible, focused, let cursor = builder.cursor, cursor.visible, cursor.blinking, elapsed < Self.blinkDuration else { return }
        let next = (floor(elapsed / Self.blinkInterval) + 1) * Self.blinkInterval - elapsed
        // The wake past `blinkDuration` draws the cursor shown, whatever phase it was left in.
        let timer = Timer(timeInterval: next, repeats: false) { [weak self] _ in
            self?.needsFrame = true
            self?.link?.isPaused = false
        }
        timer.tolerance = 0.02
        RunLoop.current.add(timer, forMode: .default)
        blinkTimer = timer
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop, !stopped.load(ordering: .acquiring) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

/// A view's search. Scans run on `TerminalView.searchQueue`; the renderer reads the matches on
/// screen. Lock order: the terminal lock, then this one.
final class TerminalSearchState: @unchecked Sendable {
    let generation = Atomic<Int>(0)
    private let lock = OSAllocatedUnfairLock()
    private var search: VTSearch?

    func run(_ query: String, generation expected: Int, session: TerminalSession) -> Int? {
        let current = { self.generation.load(ordering: .acquiring) == expected }
        guard current() else { return nil }
        session.withLockedTerminal { terminal in
            lock.withLockUnchecked {
                if search == nil { search = VTSearch(terminal: terminal) }
                search?.setNeedle(query)
            }
            if query.isEmpty { terminal.clearSelection() }
        }
        guard !query.isEmpty else { return 0 }
        // Each tick only reads the search's own copy: neither lock is held across the scan, so
        // output keeps flowing and frames keep drawing while history is searched.
        while current() {
            switch lock.withLockUnchecked({ search?.tick() ?? .complete }) {
            case .complete:
                return session.withLockedTerminal { terminal in
                    lock.withLockUnchecked {
                        let count = search?.matchCount ?? 0
                        if count > 0 { search?.step(older: true, terminal: terminal) } else { terminal.clearSelection() }
                        return count
                    }
                }
            case .feedRequired:
                session.withLockedTerminal { _ in lock.withLockUnchecked { search?.feed() } }
            case .running:
                continue
            }
        }
        return nil
    }

    func step(older: Bool, session: TerminalSession) {
        session.withLockedTerminal { terminal in
            lock.withLockUnchecked { search?.step(older: older, terminal: terminal) }
        }
    }

    func end(session: TerminalSession) {
        session.withLockedTerminal { terminal in
            lock.withLockUnchecked {
                search?.setNeedle("")
                search = nil
            }
            terminal.clearSelection()
        }
    }

    /// For the renderer, which already holds the terminal lock: empty without a search, nil while
    /// a scan holds the search (the previous frame's highlights then stay).
    func viewportMatches(terminal: VTTerminal) -> [(row: Int, columns: ClosedRange<Int>)]? {
        lock.withLockIfAvailableUnchecked { search?.viewportMatches(terminal: terminal) ?? [] }
    }
}
