import AppKit

/// One labeled, colored line in the debug overlay's ownership legend.
struct InteractionOwnershipLine: Equatable {
    let label: String
    let color: NSColor
}

/// Immutable snapshot of the capture, hover and focus ownership lifetimes; the overlay redraws only when a new one is unequal.
struct InteractionOwnershipSnapshot: Equatable {
    /// Gestural-grab owner; `nil` when no capture is active.
    let capture: ChromeEventRouter.Target?
    /// Momentary, whatever is under the pointer now.
    let hover: ChromeEventRouter.Target
    /// Persistent keyboard owner.
    let focus: ChromeEventRouter.Target

    /// Pure render: the three legend lines, in fixed order, with per-owner color.
    /// This is the unit-tested surface; `draw(_:)` only paints what this returns.
    static func lines(_ snapshot: InteractionOwnershipSnapshot) -> [InteractionOwnershipLine] {
        [
            InteractionOwnershipLine(
                label: "capture: \(name(snapshot.capture))",
                color: color(snapshot.capture)
            ),
            InteractionOwnershipLine(
                label: "hover: \(name(snapshot.hover))",
                color: color(snapshot.hover)
            ),
            InteractionOwnershipLine(
                label: "focus: \(name(snapshot.focus))",
                color: color(snapshot.focus)
            )
        ]
    }

    private static func name(_ target: ChromeEventRouter.Target?) -> String {
        switch target {
        case .some(.chrome): return "chrome"
        case .some(.content): return "content"
        case .some(.none), nil: return "none"
        }
    }

    private static func color(_ target: ChromeEventRouter.Target?) -> NSColor {
        switch target {
        case .some(.chrome): return .systemGreen
        case .some(.content): return .systemRed
        case .some(.none), nil: return .systemGray
        }
    }
}

final class HitboxDebugOverlayView: NSView {
    var zones: [String: NSRect] = [:] {
        didSet { needsDisplay = true }
    }
    var testedPoint: NSPoint? {
        didSet { needsDisplay = true }
    }
    var testedPointIsInteractive = false {
        didSet { needsDisplay = true }
    }

    /// An equal snapshot does nothing, so a mouse move that changes no ownership skips the legend repaint (the dot redraws on its own).
    var ownership: InteractionOwnershipSnapshot? {
        didSet {
            guard ownership != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        NSColor.systemYellow.withAlphaComponent(0.75).setStroke()
        for (_, rect) in zones {
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }

        drawOwnershipLegend()

        guard let testedPoint else { return }
        let color = testedPointIsInteractive
            ? NSColor.systemGreen
            : NSColor.systemRed
        color.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: testedPoint.x - 4,
                y: testedPoint.y - 4,
                width: 8,
                height: 8
            )
        ).fill()
    }

    private func drawOwnershipLegend() {
        guard let ownership else { return }
        let lines = InteractionOwnershipSnapshot.lines(ownership)

        let inset: CGFloat = 12
        let lineHeight: CGFloat = 18
        let padding: CGFloat = 8
        let panelWidth: CGFloat = 180
        let panelHeight = padding * 2 + lineHeight * CGFloat(lines.count)
        let panel = NSRect(x: inset, y: inset, width: panelWidth, height: panelHeight)

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        for (index, line) in lines.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: line.color
            ]
            let origin = NSPoint(
                x: panel.minX + padding,
                y: panel.minY + padding + lineHeight * CGFloat(index)
            )
            (line.label as NSString).draw(at: origin, withAttributes: attrs)
        }
    }
}
