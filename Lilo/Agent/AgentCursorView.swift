import AppKit
import WebKit

/// The agents' color in Lilo (the sidebar's activity dot).
private let agentColor = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

/// Where the agent's pointer is, drawn over its web view so the user can follow it: a coral arrow
/// with the agent's name beside it, like a collaborator's cursor. A native view, not page content:
/// agent screenshots never show it, and it lets the user's own mouse through.
@MainActor
final class AgentCursorView: NSView {
    /// The arrow's tip in its own image.
    static let hotSpot = CGPoint(x: 3, y: 2)

    private let arrow = NSImageView(image: AgentCursorView.arrowImage)
    private let label = NSTextField(labelWithString: "")
    // A label draws its text at the top of its frame: the pill carries the height and centers it.
    private let pill = NSView()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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

    private func place(at point: CGPoint, animator: Bool = false) {
        let origin = CGPoint(x: point.x - Self.hotSpot.x, y: point.y - Self.hotSpot.y)
        let labelOrigin = CGPoint(x: point.x + 12, y: point.y + 18)
        if animator {
            arrow.animator().setFrameOrigin(origin)
            pill.animator().setFrameOrigin(labelOrigin)
        } else {
            arrow.setFrameOrigin(origin)
            pill.setFrameOrigin(labelOrigin)
        }
        arrow.setFrameSize(Self.arrowImage.size)
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
        }, completionHandler: { ring.removeFromSuperview() })
    }

    /// A coral arrow with a white outline, so it reads on any page and never passes for the user's.
    private static let arrowImage: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 26), flipped: true) { _ in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 3, y: 2))
            path.line(to: CGPoint(x: 3, y: 21))
            path.line(to: CGPoint(x: 8.2, y: 16.2))
            path.line(to: CGPoint(x: 11.5, y: 23.6))
            path.line(to: CGPoint(x: 14.8, y: 22.1))
            path.line(to: CGPoint(x: 11.5, y: 14.9))
            path.line(to: CGPoint(x: 18.5, y: 14.6))
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

/// A tab an agent controls: a coral edge around the page and a badge naming the agent, so the
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
        if !shown.isEmpty { frame = shown }
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
    }
}
