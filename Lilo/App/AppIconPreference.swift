import AppKit

/// User-selectable app icon: macOS has no alternate-icon API, so a variant is set on the Dock tile and on the bundle itself.
/// Only `classic` follows the system's dark, tinted and clear styles. Cached so launch can re-apply it after a reinstall wipes it.
enum AppIconPreference {
    static let variants = ["classic", "night", "frost", "blueprint", "riso", "pixel", "neon", "graphite", "spring", "pride", "clay"]

    private static let cacheKey = "lilo.appIcon"

    @MainActor private static var swapView: DockIconSwapView?
    @MainActor private static var swapTimer: Timer?

    @MainActor static func apply(_ name: String) {
        let variant = variants.contains(name) ? name : "classic"
        let image = variant == "classic"
            ? nil
            : Bundle.main.url(forResource: variant, withExtension: "png", subdirectory: "AppIcons").flatMap(NSImage.init(contentsOf:))
        let oldImage = NSApp.applicationIconImage
        // The download progress view owns the Dock tile while downloads run.
        let animate = variant != UserDefaults.lilo.string(forKey: cacheKey) ?? "classic"
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !(NSApp.dockTile.contentView is DownloadDockProgressController.DockProgressView)
        UserDefaults.lilo.set(variant, forKey: cacheKey)
        if animate { animateDockSwap(from: oldImage, to: image) } else { setIcon(image) }
    }

    /// nil restores the bundle's own icon on both surfaces.
    @MainActor private static func setIcon(_ image: NSImage?) {
        // Replaces the Dock tile's contentView, so it only runs once the swap animation is over.
        NSApp.applicationIconImage = image
        // Must stay on the main thread: off it, the Dock can show a generic folder icon.
        NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
    }

    /// 128 px PNG data URLs for the settings grid, built once from the bundled images.
    @MainActor static let previews: [[String: String]] = variants.compactMap { variant in
        let image = variant == "classic"
            ? Bundle.main.image(forResource: "AppIcon")
            : Bundle.main.url(forResource: variant, withExtension: "png", subdirectory: "AppIcons").flatMap(NSImage.init(contentsOf:))
        guard let image else { return nil }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return ["id": variant, "dataURL": "data:image/png;base64," + png.base64EncodedString()]
    }

    /// The Dock tile only redraws on display(), so the swap is driven frame by frame. It stops early
    /// when anything else takes the tile's contentView; the icon is set either way.
    @MainActor private static func animateDockSwap(from old: NSImage?, to new: NSImage?) {
        let tile = NSApp.dockTile
        swapTimer?.invalidate()
        let view = DockIconSwapView(from: old, to: new)
        swapView = view
        tile.contentView = view
        tile.display()
        let start = CACurrentMediaTime()
        swapTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let tile = NSApp.dockTile
                let progress = (CACurrentMediaTime() - start) / DockIconSwapView.duration
                guard let view = swapView, tile.contentView === view, progress < 1 else {
                    swapTimer?.invalidate()
                    swapTimer = nil
                    if let view = swapView { setIcon(view.new) }
                    swapView = nil
                    return
                }
                view.progress = progress
                tile.display()
            }
        }
    }

    @MainActor static func applyCachedAtLaunch() {
        guard let cached = UserDefaults.lilo.string(forKey: cacheKey), cached != "classic", variants.contains(cached),
              let image = Bundle.main.url(forResource: cached, withExtension: "png", subdirectory: "AppIcons").flatMap(NSImage.init(contentsOf:))
        else { return }
        NSApp.applicationIconImage = image
        // The bundle's custom icon (its `Icon\r` file) survives relaunches; only a reinstall wipes it, and
        // rewriting it makes Finder and the Dock refresh.
        if !FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Icon\r") {
            NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
        }
    }
}

/// Old icon shrinks away, then the new one springs in with a slight overshoot.
private final class DockIconSwapView: NSView {
    static let duration: CFTimeInterval = 0.6
    private static let outShare = 0.35

    private let old: NSImage?
    /// nil is the bundle's own icon, as in `apply`.
    let new: NSImage?
    private let newDrawn: NSImage?
    var progress: Double = 0

    init(from old: NSImage?, to new: NSImage?) {
        self.old = old
        self.new = new
        newDrawn = new ?? Bundle.main.image(forResource: "AppIcon")
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let image: NSImage?
        let scale: Double
        if progress < Self.outShare {
            let t = progress / Self.outShare
            image = old
            scale = 1 - t * t
        } else {
            let t = (progress - Self.outShare) / (1 - Self.outShare)
            image = newDrawn
            scale = 1 - exp(-5 * t) * cos(3 * .pi * t)
        }
        let side = bounds.width * scale
        image?.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
    }
}
