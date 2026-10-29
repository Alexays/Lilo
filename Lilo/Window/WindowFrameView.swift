import AppKit

/// Distances from each window edge to the content hole, the content inset included.
struct ContentEdges: Equatable {
    var left: CGFloat
    var right: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    static func uniform(_ inset: CGFloat) -> ContentEdges {
        ContentEdges(left: inset, right: inset, top: inset, bottom: inset)
    }
}

/// Pure frame geometry: four opaque bands tiling everything outside the content
/// hole, plus four corner squares carrying the concave rounded-corner bites.
/// Bottom-left-origin (CALayer) coordinates, matching `contentFrameRect()`.
struct WindowFrameGeometry: Equatable {
    var contentHole: CGRect
    var leftBand: CGRect
    var rightBand: CGRect
    var topBand: CGRect
    var bottomBand: CGRect
    var topLeftCorner: CGRect
    var topRightCorner: CGRect
    var bottomLeftCorner: CGRect
    var bottomRightCorner: CGRect
    /// Effective corner radius after clamping to the hole size.
    var cornerRadius: CGFloat

    init(size: CGSize, edges: ContentEdges, cornerRadius: CGFloat) {
        let hole = CGRect(
            x: edges.left,
            y: edges.bottom,
            width: max(0, size.width - edges.left - edges.right),
            height: max(0, size.height - edges.top - edges.bottom)
        )
        contentHole = hole
        leftBand = CGRect(x: 0, y: 0, width: hole.minX, height: size.height)
        rightBand = CGRect(x: hole.maxX, y: 0, width: max(0, size.width - hole.maxX), height: size.height)
        bottomBand = CGRect(x: hole.minX, y: 0, width: hole.width, height: hole.minY)
        topBand = CGRect(x: hole.minX, y: hole.maxY, width: hole.width, height: max(0, size.height - hole.maxY))

        let radius = max(0, min(cornerRadius, hole.width / 2, hole.height / 2))
        self.cornerRadius = radius
        bottomLeftCorner = CGRect(x: hole.minX, y: hole.minY, width: radius, height: radius)
        topLeftCorner = CGRect(x: hole.minX, y: hole.maxY - radius, width: radius, height: radius)
        bottomRightCorner = CGRect(x: hole.maxX - radius, y: hole.minY, width: radius, height: radius)
        topRightCorner = CGRect(x: hole.maxX - radius, y: hole.maxY - radius, width: radius, height: radius)
    }
}

/// Native opaque frame around the content (sidebar band, inset ring, rounded corners) as CALayers between content and chrome web views,
/// so color fades and the sidebar toggle stay compositor work instead of web-process raster and layout.
final class WindowFrameView: NSView {
    /// Matches `--chrome-overlay-boundary-radius` (`--radius-md`) in the chrome UI.
    static let contentCornerRadius: CGFloat = 10
    /// Matches the chrome sidebar slide: `--motion-duration-slow` with `--motion-ease-standard`.
    static let toggleDuration: TimeInterval = 0.28
    static let toggleTiming = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    /// Matches the chrome sidebar's `background-color 0.34s var(--motion-ease-spring)` fade.
    static let colorFadeDuration: TimeInterval = 0.34
    private static let colorFadeTiming = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    private(set) var edges: ContentEdges
    private var frameColor: CGColor?
    private var cornerPathRadius: CGFloat = -1

    private let leftBand = CALayer()
    private let rightBand = CALayer()
    private let topBand = CALayer()
    private let bottomBand = CALayer()
    private let topLeftCorner = CAShapeLayer()
    private let topRightCorner = CAShapeLayer()
    private let bottomLeftCorner = CAShapeLayer()
    private let bottomRightCorner = CAShapeLayer()

    private var bandLayers: [CALayer] { [leftBand, rightBand, topBand, bottomBand] }
    private var cornerLayers: [CAShapeLayer] { [topLeftCorner, topRightCorner, bottomLeftCorner, bottomRightCorner] }

    init(frame: NSRect, edges: ContentEdges) {
        self.edges = edges
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for band in bandLayers {
            band.isOpaque = true
            layer?.addSublayer(band)
        }
        for corner in cornerLayers {
            corner.fillRule = .evenOdd
            corner.masksToBounds = true
            layer?.addSublayer(corner)
        }
        applyLayout(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Click-through: the shield/zone routing decides chrome vs content, never this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Standalone sublayers don't inherit the backing scale from AppKit; without this the
    /// rasterized corner bites stay at 1x and blur on retina (and on display moves).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        cornerLayers.forEach { $0.contentsScale = scale }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout(animated: false)
    }

    /// Updates the content hole. Non-animated sets are cheap layer-frame writes
    /// (sidebar live-resize drag); animated runs the 280ms compositor-only curtain sweep.
    func setEdges(_ edges: ContentEdges, animated: Bool, completion: (() -> Void)? = nil) {
        self.edges = edges
        applyLayout(animated: animated, completion: completion)
    }

    /// Applies the frame color, fading from the current presentation value. The first
    /// set (bootstrap/default path, before any bridge message) is applied instantly, and so is
    /// each frame of a swipe, which already moves the color with the finger.
    func setFrameColor(_ color: NSColor, animated: Bool = true) {
        let cgColor = color.cgColor
        guard cgColor != frameColor else { return }
        let fade = animated && frameColor != nil
        frameColor = cgColor

        CATransaction.begin()
        if fade {
            CATransaction.setAnimationDuration(Self.colorFadeDuration)
            CATransaction.setAnimationTimingFunction(Self.colorFadeTiming)
        } else {
            CATransaction.setDisableActions(true)
        }
        bandLayers.forEach { $0.backgroundColor = cgColor }
        cornerLayers.forEach { $0.fillColor = cgColor }
        CATransaction.commit()
    }

    private func applyLayout(animated: Bool, completion: (() -> Void)? = nil) {
        let geometry = WindowFrameGeometry(
            size: bounds.size,
            edges: edges,
            cornerRadius: Self.contentCornerRadius
        )
        updateCornerPathsIfNeeded(radius: geometry.cornerRadius)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Self.toggleDuration)
            CATransaction.setAnimationTimingFunction(Self.toggleTiming)
        } else {
            CATransaction.setDisableActions(true)
            // Geometry is authoritative: drop any in-flight curtain animation so a window
            // resize or sidebar drag mid-toggle cannot leave layers gliding to stale frames.
            for sublayer in bandLayers + cornerLayers {
                sublayer.removeAnimation(forKey: "position")
                sublayer.removeAnimation(forKey: "bounds")
            }
        }
        if let completion { CATransaction.setCompletionBlock(completion) }
        leftBand.frame = geometry.leftBand
        rightBand.frame = geometry.rightBand
        topBand.frame = geometry.topBand
        bottomBand.frame = geometry.bottomBand
        topLeftCorner.frame = geometry.topLeftCorner
        topRightCorner.frame = geometry.topRightCorner
        bottomLeftCorner.frame = geometry.bottomLeftCorner
        bottomRightCorner.frame = geometry.bottomRightCorner
        CATransaction.commit()
    }

    private func updateCornerPathsIfNeeded(radius: CGFloat) {
        guard radius != cornerPathRadius else { return }
        cornerPathRadius = radius
        // Circle center sits on the corner square's vertex diagonal to the hole corner.
        topLeftCorner.path = Self.cornerBitePath(radius: radius, circleCenter: CGPoint(x: radius, y: 0))
        topRightCorner.path = Self.cornerBitePath(radius: radius, circleCenter: CGPoint(x: 0, y: 0))
        bottomLeftCorner.path = Self.cornerBitePath(radius: radius, circleCenter: CGPoint(x: radius, y: radius))
        bottomRightCorner.path = Self.cornerBitePath(radius: radius, circleCenter: CGPoint(x: 0, y: radius))
    }

    /// Square minus the rounded-corner disk (even-odd fill, clipped to bounds): the
    /// concave "bite" that rounds one content corner.
    static func cornerBitePath(radius: CGFloat, circleCenter: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: radius, height: radius))
        path.addEllipse(in: CGRect(
            x: circleCenter.x - radius,
            y: circleCenter.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        return path
    }
}
