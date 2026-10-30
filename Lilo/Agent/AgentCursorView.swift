import AppKit
import WebKit

/// The agents' color in Lilo (the sidebar's activity dot).
private let agentColor = NSColor(srgbRed: 0x79 / 255, green: 0x5C / 255, blue: 0xEB / 255, alpha: 1)

/// Where the agent's pointer is, drawn over its web view so the user can follow it: a violet arrow
/// trailed by a little mascot carrying the agent's name, like a collaborator's cursor. A native view, not page content:
/// agent screenshots never show it, and it lets the user's own mouse through.
@MainActor
final class AgentCursorView: NSView {
    /// The arrow's tip in its own image.
    static let hotSpot = CGPoint(x: 3, y: 2)

    /// The mascot at rest, standing for an Agents space in a menu.
    static let menuImage = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
        let scale = rect.width / 22
        agentColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.setFill()
        for x: CGFloat in [5, 13] {
            let eye = CGRect(x: x * scale, y: 7.5 * scale, width: 4 * scale, height: 5 * scale)
            NSBezierPath(roundedRect: eye, xRadius: 2 * scale, yRadius: 2 * scale).fill()
        }
        return true
    }

    private let arrow = NSImageView(image: AgentCursorView.arrowImage)
    private let label = NSTextField(labelWithString: "")
    // A label draws its text at the top of its frame: the pill carries the height and centers it.
    private let pill = NSView()
    // A round violet mascot with two eyes, trailing the arrow.
    private let blob = NSView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
    private let body = CALayer()
    private let eyes = CALayer()
    private var blinkTimer: Timer?
    private var mood: Mood?
    private var moodLayers: [CALayer] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blob.wantsLayer = true
        body.frame = blob.bounds
        body.cornerRadius = 11
        body.backgroundColor = agentColor.cgColor
        body.borderWidth = 1.5
        body.borderColor = NSColor.white.cgColor
        eyes.frame = body.bounds
        for x: CGFloat in [5, 13] {
            let eye = CALayer()
            eye.frame = CGRect(x: x, y: 9.5, width: 4, height: 5)
            eye.cornerRadius = 2
            eye.backgroundColor = NSColor.white.cgColor
            eyes.addSublayer(eye)
        }
        body.addSublayer(eyes)
        blob.layer?.addSublayer(body)
        addSubview(blob)
        addSubview(arrow)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        pill.wantsLayer = true
        pill.layer?.backgroundColor = agentColor.cgColor
        pill.layer?.cornerRadius = 9
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        pill.addSubview(label)
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A press jumps there, so the arrow is on the spot as the click lands; a hover glides.
    static func show(in webView: WKWebView, at point: CGPoint, pressed: Bool = false, animated: Bool = false) {
        let cursor = webView.subviews.lazy.compactMap { $0 as? AgentCursorView }.first ?? {
            let cursor = AgentCursorView(frame: webView.bounds)
            cursor.autoresizingMask = [.width, .height]
            cursor.place(at: point)
            webView.addSubview(cursor)
            return cursor
        }()
        // The tab's frame may arrive after the first move: the name is read on every show.
        let name = webView.subviews.lazy.compactMap { $0 as? AgentFrameView }.first?.agentName ?? "Agent".localized
        if cursor.label.stringValue != name {
            cursor.label.stringValue = name
            cursor.label.sizeToFit()
            let height: CGFloat = 18
            let width = min(cursor.label.frame.width + 16, 160)
            cursor.pill.frame.size = CGSize(width: width, height: height)
            cursor.label.frame = CGRect(
                x: 8, y: (height - cursor.label.frame.height) / 2,
                width: width - 16, height: cursor.label.frame.height
            )
        }
        // The web view's own subviews come and go: the cursor stays on top of them.
        if webView.subviews.last !== cursor { webView.addSubview(cursor, positioned: .above, relativeTo: nil) }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                cursor.place(at: point, animator: true)
            }
        } else {
            cursor.place(at: point)
        }
        if pressed { cursor.ripple(at: point) }
    }

    /// The arrow is exact; the mascot and its name tag trail it on a spring, like a companion.
    private func place(at point: CGPoint, animator: Bool = false) {
        let origin = CGPoint(x: point.x - Self.hotSpot.x, y: point.y - Self.hotSpot.y)
        if animator {
            arrow.animator().setFrameOrigin(origin)
        } else {
            arrow.setFrameOrigin(origin)
        }
        arrow.setFrameSize(Self.arrowImage.size)

        let previous = blob.layer.map { $0.presentation()?.position ?? $0.position }
        let previousPill = pill.layer.map { $0.presentation()?.position ?? $0.position }
        blob.setFrameOrigin(CGPoint(x: point.x + 11, y: point.y + 15))
        pill.setFrameOrigin(CGPoint(x: point.x + 36, y: point.y + 17))
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = blob.layer, let previous, let pillLayer = pill.layer, let previousPill else { return }
        let dx = layer.position.x - previous.x
        let distance = hypot(dx, layer.position.y - previous.y)
        guard distance > 1 else { return }
        var duration: CFTimeInterval = 0
        for (moving, from) in [(layer, previous), (pillLayer, previousPill)] {
            let follow = CASpringAnimation(keyPath: "position")
            follow.stiffness = 60
            follow.damping = 8.5
            follow.duration = follow.settlingDuration
            follow.fromValue = NSValue(point: from)
            follow.toValue = NSValue(point: moving.position)
            moving.add(follow, forKey: "follow")
            duration = follow.duration
        }
        // Looks where it goes, then back at the page.
        let look = CAKeyframeAnimation(keyPath: "transform.translation.x")
        look.values = [0, dx / distance * 2, dx / distance * 2, 0]
        look.keyTimes = [0, 0.15, 0.6, 1]
        look.duration = duration
        eyes.add(look, forKey: "look")
        guard distance > 20 else { return }
        let stretch = min(0.15, distance / 600)
        for (key, amount) in [("transform.scale.x", stretch), ("transform.scale.y", -stretch * 0.8)] {
            let squash = CAKeyframeAnimation(keyPath: key)
            squash.values = [1, 1 + amount, 1]
            squash.duration = 0.45
            body.add(squash, forKey: key)
        }
    }

    // Blinks on a timer only while shown: a repeating Core Animation blink would keep the compositor busy.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
                blink.values = [1, 0.15, 1]
                blink.duration = 0.14
                self?.eyes.add(blink, forKey: "blink")
            }
        }
        blinkTimer?.tolerance = 0.5
    }

    /// What the mascot acts out while a call runs on its tab, so a still pointer never reads as stuck.
    enum Mood: String {
        case working, reading, scripting, typing, capturing, loading, waitingForUser

        init(tool: String, action: String?) {
            self = switch (tool, action) {
            case ("read_page", _), ("get_page_text", _), ("find", _), ("read_console_messages", _), ("read_network_requests", _): .reading
            case ("javascript_tool", _), ("run", _), ("devtools_command", _), ("devtools_events", _), ("performance", _),
                 ("network_mock", _), ("network_response", _), ("emulate", _), ("cookies", _): .scripting
            case ("form_input", _), ("file_upload", _), ("upload_image", _), ("computer", "type"), ("computer", "insert_text"),
                 ("computer", "key"): .typing
            case ("gif_creator", _), ("computer", "screenshot"), ("computer", "zoom"): .capturing
            case ("navigate", _), ("wait_for", _), ("fetch", _), ("computer", "wait"): .loading
            default: .working
            }
        }
    }

    static func setMood(_ mood: Mood?, in webView: WKWebView) {
        guard let cursor = webView.subviews.lazy.compactMap({ $0 as? AgentCursorView }).first, cursor.mood != mood else { return }
        cursor.mood = mood
        cursor.body.removeAnimation(forKey: "mood")
        cursor.eyes.removeAnimation(forKey: "mood")
        cursor.moodLayers.forEach { $0.removeFromSuperlayer() }
        cursor.moodLayers = []
        guard let mood, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let host = cursor.blob.layer else { return }

        func loop(_ keyPath: String, _ values: [Any], _ duration: CFTimeInterval, keyTimes: [NSNumber]? = nil, smooth: Bool = false) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.duration = duration
            animation.repeatCount = .infinity
            if smooth { animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
            return animation
        }
        func extra(size: CGFloat, above: Bool = true) -> CALayer {
            let layer = CALayer()
            layer.frame = CGRect(x: (22 - size) / 2, y: (22 - size) / 2, width: size, height: size)
            layer.cornerRadius = size / 2
            if above { host.addSublayer(layer) } else { host.insertSublayer(layer, at: 0) }
            cursor.moodLayers.append(layer)
            return layer
        }
        // The layer's y axis points up: a positive translation lifts.
        switch mood {
        case .working:
            cursor.body.add(loop("transform.translation.y", [0, 2.5, 0], 0.7, smooth: true), forKey: "mood")
            cursor.eyes.add(loop("transform.translation.x", [0, -2, -2, 2, 2, 0], 2.4, keyTimes: [0, 0.15, 0.4, 0.55, 0.85, 1]), forKey: "mood")
        case .reading:
            // Line by line: across, then back to the start of the next one down.
            let lines: [CGFloat] = [0.7, -0.3, -1.3]
            let values = lines.flatMap { y in [NSValue(size: CGSize(width: -2, height: y)), NSValue(size: CGSize(width: 2, height: y))] }
            cursor.eyes.add(loop("transform.translation", values + [values[0]], 2.4, keyTimes: [0, 0.3, 0.33, 0.63, 0.66, 0.96, 1]), forKey: "mood")
        case .scripting:
            cursor.body.add(loop("transform.translation.x", [0, -0.5, 0, 0.5, 0], 0.18), forKey: "mood")
            cursor.eyes.add(loop("transform.scale.y", [0.45, 0.6, 0.45], 1.2), forKey: "mood")
            for index in 0..<3 {
                let dot = extra(size: 2.5)
                dot.position = CGPoint(x: 7 + CGFloat(index) * 4, y: 27)
                dot.backgroundColor = agentColor.cgColor
                let blink = loop("opacity", [0.25, 1, 0.25], 0.9)
                blink.beginTime = CACurrentMediaTime() + Double(index) * 0.3
                dot.add(blink, forKey: "mood")
            }
        case .typing:
            cursor.body.add(loop("transform.translation.y", [0, -1, 0, -1, 0, 0], 0.6, keyTimes: [0, 0.1, 0.2, 0.35, 0.45, 1]), forKey: "mood")
            cursor.eyes.add(loop("transform.translation.y", [-1.7, -1.7], 1), forKey: "mood")
        case .capturing:
            cursor.eyes.add(loop("transform.scale.y", [1, 1, 0.1, 1, 1], 1.4, keyTimes: [0, 0.7, 0.78, 0.86, 1]), forKey: "mood")
            let ring = extra(size: 22)
            ring.borderWidth = 1.2
            ring.borderColor = NSColor.white.cgColor
            ring.opacity = 0
            let flash = CAAnimationGroup()
            flash.animations = [
                loop("opacity", [0, 0, 1, 0], 1.4, keyTimes: [0, 0.74, 0.78, 1]),
                loop("transform.scale", [1, 1, 1, 1.8], 1.4, keyTimes: [0, 0.74, 0.78, 1])
            ]
            flash.duration = 1.4
            flash.repeatCount = .infinity
            ring.add(flash, forKey: "mood")
        case .loading:
            cursor.body.add(loop("transform.rotation.z", [0.1, -0.1, 0.1], 1.1, smooth: true), forKey: "mood")
            // A dot riding the rim of a turning layer the size of the orbit.
            let orbit = extra(size: 32)
            let dot = CALayer()
            dot.frame = CGRect(x: 30 - 4, y: 16 - 2, width: 4, height: 4)
            dot.cornerRadius = 2
            dot.backgroundColor = agentColor.cgColor
            dot.borderWidth = 0.7
            dot.borderColor = NSColor.white.cgColor
            orbit.addSublayer(dot)
            orbit.add(loop("transform.rotation.z", [0, -2 * CGFloat.pi], 1.1), forKey: "mood")
        case .waitingForUser:
            cursor.eyes.add(loop("transform.translation.y", [2, 2.7, 2], 1.8, smooth: true), forKey: "mood")
            let halo = extra(size: 22, above: false)
            // The white rim keeps it visible on a dark page, where the violet alone fades into it.
            halo.backgroundColor = agentColor.cgColor
            halo.borderWidth = 1
            halo.borderColor = NSColor.white.cgColor
            halo.opacity = 0
            let pulse = CAAnimationGroup()
            pulse.animations = [loop("transform.scale", [1, 1.6], 1.8), loop("opacity", [0.6, 0], 1.8)]
            pulse.duration = 1.8
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            halo.add(pulse, forKey: "mood")
        }
    }

    private func ripple(at point: CGPoint) {
        let size: CGFloat = 28
        let ring = NSView(frame: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        ring.wantsLayer = true
        ring.layer?.cornerRadius = size / 2
        ring.layer?.borderWidth = 2
        ring.layer?.borderColor = agentColor.cgColor
        ring.layer?.backgroundColor = agentColor.withAlphaComponent(0.2).cgColor
        addSubview(ring, positioned: .below, relativeTo: arrow)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            ring.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { ring.removeFromSuperview() } })
    }

    /// A violet arrow with a white outline, so it reads on any page and never passes for the user's.
    private static let arrowImage: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 26), flipped: true) { _ in
            // A soft pointer without a stem: tip, bottom, notch and right wing, each corner rounded.
            let corners: [(CGPoint, CGFloat)] = [
                // Small radii: on corners this sharp a larger one eats several points of the shape.
                (CGPoint(x: 3, y: 2), 1), (CGPoint(x: 3.4, y: 22.5), 1.4),
                (CGPoint(x: 9, y: 16.4), 1.6), (CGPoint(x: 19.5, y: 15.2), 1.4)
            ]
            let path = NSBezierPath()
            let (last, first) = (corners[corners.count - 1].0, corners[0].0)
            path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
            for (index, (corner, radius)) in corners.enumerated() {
                path.appendArc(from: corner, to: corners[(index + 1) % corners.count].0, radius: radius)
            }
            path.close()
            path.lineJoinStyle = .round
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.set()
            agentColor.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            path.lineWidth = 1.6
            path.stroke()
            return true
        }
        return image
    }()
}

/// A tab an agent controls: a violet edge around the page and a badge naming the agent, so the
/// page says it is being driven even while the pointer is still. Lets the user's mouse through.
@MainActor
final class AgentFrameView: NSView {
    let agentName: String
    private let badge = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(frame: NSRect, agentName: String) {
        self.agentName = agentName
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.borderColor = agentColor.cgColor
        layer?.cornerRadius = WindowFrameView.contentCornerRadius
        layer?.shadowColor = agentColor.cgColor
        badge.stringValue = String(format: "%@ controls this tab".localized, agentName)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.sizeToFit()
        // A label draws its text at the top of its frame: the pill carries the height and centers it.
        let pill = NSView(frame: CGRect(x: 0, y: 0, width: badge.frame.width + 16, height: 20))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = agentColor.cgColor
        pill.layer?.cornerRadius = 10
        badge.setFrameOrigin(CGPoint(x: 8, y: (pill.frame.height - badge.frame.height) / 2))
        pill.addSubview(badge)
        pill.autoresizingMask = [.minXMargin]
        pill.setFrameOrigin(CGPoint(x: frame.width - pill.frame.width - 10, y: 10))
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The page keeps the agent's viewport, larger than a small window: the frame and badge stay on the part shown.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fitShownPart()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitShownPart()
        guard window != nil, let page = superview, let container = page.superview else { return }
        for view in [page, container] {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(fitShownPart), name: NSView.frameDidChangeNotification, object: view)
        }
    }

    @objc private func fitShownPart() {
        guard let page = superview, let container = page.superview else { return }
        let shown = page.bounds.intersection(page.convert(container.bounds, from: container))
        guard !shown.isEmpty, let layer, let pageLayer = page.layer else { return }
        frame = shown
        // A page wider or taller than its container has its own rounded corners cut off: round the part
        // shown. A mask renders offscreen, so a page shown whole goes without.
        guard shown != page.bounds else {
            pageLayer.mask = nil
            return
        }
        let mask = pageLayer.mask ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = NSColor.black.cgColor
        mask.cornerRadius = WindowFrameView.contentCornerRadius
        mask.frame = layer.frame
        CATransaction.commit()
        pageLayer.mask = mask
    }

    /// Frames `webView` for `agentName`; the cursor stays above the frame.
    static func show(on webView: WKWebView, agentName: String) {
        guard !webView.subviews.contains(where: { $0 is AgentFrameView }) else { return }
        let frame = AgentFrameView(frame: webView.bounds, agentName: agentName)
        frame.autoresizingMask = [.width, .height]
        let cursor = webView.subviews.first { $0 is AgentCursorView }
        webView.addSubview(frame, positioned: cursor == nil ? .above : .below, relativeTo: cursor)
    }

    static func remove(from webView: WKWebView) {
        webView.subviews.filter { $0 is AgentFrameView || $0 is AgentCursorView }.forEach { $0.removeFromSuperview() }
        webView.layer?.mask = nil
    }
}
