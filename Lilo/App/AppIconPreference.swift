import AppKit

/// User-selectable app icon: macOS has no alternate-icon API, so a variant is set on the Dock tile and on the bundle itself.
/// Only `classic` follows the system's dark, tinted and clear styles. Cached so launch can re-apply it after a reinstall wipes it.
/// During a season (`AppIcons/<season>/`), every variant shows its seasonal version unless the setting turns that off.
enum AppIconPreference {
    static let variants = ["classic", "night", "frost", "blueprint", "riso", "pixel", "neon", "graphite", "spring", "pride", "clay"]
    /// Mirrors the `seasonalAppIcon` setting: launch reads it before the settings store opens.
    static let seasonalKey = "seasonalAppIcon"

    private static let cacheKey = "lilo.appIcon"
    /// Path of the image last written on the bundle, "" for its own icon.
    private static let bundleIconKey = "lilo.appIconBundle"

    @MainActor private static var swapView: DockIconSwapView?
    @MainActor private static var swapTimer: Timer?

    @MainActor static func apply(_ name: String) {
        UserDefaults.lilo.set(variants.contains(name) ? name : "classic", forKey: cacheKey)
        refresh()
    }

    @MainActor static func setSeasonal(_ enabled: Bool) {
        UserDefaults.lilo.set(enabled, forKey: seasonalKey)
        refresh()
    }

    /// Halloween runs from October 24 through 31, Christmas from December 15 through 26, New Year from December 31
    /// through January 1, Valentine's Day on February 14, Lilo's birthday on April 22, summer from June 20 through 22,
    /// Easter from Good Friday through Easter Monday, Lunar New Year over the first week of the lunar year.
    static func season(on date: Date) -> String? {
        let calendar = Calendar.current
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        switch (day.month, day.day ?? 0) {
        case (10, 24...31): return "halloween"
        case (12, 15...26): return "christmas"
        case (12, 31), (1, 1): return "newyear"
        case (2, 14): return "valentine"
        case (4, 22): return "birthday"
        case (6, 20...22): return "summer"
        default:
            // Easter Sunday by the anonymous Gregorian algorithm (Meeus/Jones/Butcher).
            let year = day.year ?? 0
            let a = year % 19, b = year / 100, c = year % 100
            let g = (b - (b + 8) / 25 + 1) / 3
            let h = (19 * a + b - b / 4 - g + 15) % 30
            let l = (32 + 2 * (b % 4) + 2 * (c / 4) - h - c % 4) % 7
            let m = (a + 11 * h + 22 * l) / 451
            let n = h + l - 7 * m + 114
            if let easter = calendar.date(from: DateComponents(year: year, month: n / 31, day: n % 31 + 1)),
               let offset = calendar.dateComponents([.day], from: easter, to: calendar.startOfDay(for: date)).day,
               (-2...1).contains(offset) {
                return "easter"
            }
            let lunar = Calendar(identifier: .chinese).dateComponents([.month, .day, .isLeapMonth], from: date)
            return lunar.month == 1 && lunar.isLeapMonth != true && lunar.day ?? 0 <= 7 ? "lunar" : nil
        }
    }

    /// The image due now; nil is the bundle's own icon.
    private static func currentURL() -> URL? {
        let variant = UserDefaults.lilo.string(forKey: cacheKey) ?? "classic"
        let seasonal = UserDefaults.lilo.object(forKey: seasonalKey) as? Bool ?? true
        let season = seasonal ? season(on: Date()) : nil
        if season == nil && variant == "classic" { return nil }
        return Bundle.main.url(forResource: variant, withExtension: "png", subdirectory: season.map { "AppIcons/\($0)" } ?? "AppIcons")
    }

    @MainActor private static func refresh() {
        let url = currentURL()
        guard url?.path ?? "" != UserDefaults.lilo.string(forKey: bundleIconKey) ?? "" else { return }
        UserDefaults.lilo.set(url?.path ?? "", forKey: bundleIconKey)
        let image = url.flatMap(NSImage.init(contentsOf:))
        // The download progress view owns the Dock tile while downloads run.
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !(NSApp.dockTile.contentView is DownloadDockProgressController.DockProgressView)
        if animate { animateDockSwap(from: NSApp.applicationIconImage, to: image) } else { setIcon(image) }
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
        // A season starts or ends at midnight; the notification also follows a wake into a new day.
        _ = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        let url = currentURL()
        let image = url.flatMap(NSImage.init(contentsOf:))
        if let image { NSApp.applicationIconImage = image }
        // The bundle's custom icon (its `Icon\r` file) survives relaunches; only a reinstall wipes it, and
        // rewriting it makes Finder and the Dock refresh.
        if url?.path ?? "" != UserDefaults.lilo.string(forKey: bundleIconKey) ?? ""
            || image != nil && !FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Icon\r") {
            UserDefaults.lilo.set(url?.path ?? "", forKey: bundleIconKey)
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
