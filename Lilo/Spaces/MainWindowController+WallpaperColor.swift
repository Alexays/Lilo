// The wallpaper color a Space can follow, read from the desktop picture of the window's screen.

import AppKit
import ImageIO

extension MainWindowController {
    /// The UI turns this on only while it shows a Space that follows the wallpaper; enabling again resends the color.
    func setWallpaperColorWatch(_ enabled: Bool) {
        guard enabled else {
            for (center, token) in wallpaperColorObservers { center.removeObserver(token) }
            wallpaperColorObservers = []
            sentWallpaperKey = nil
            return
        }
        if wallpaperColorObservers.isEmpty {
            // macOS posts nothing when the wallpaper changes: these are the moments a new one can show up.
            let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.sendWallpaperColor() }
            }
            let workspace = NSWorkspace.shared.notificationCenter
            let app = NotificationCenter.default
            wallpaperColorObservers = [
                (workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: refresh)),
                (app, app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: refresh)),
                (app, app.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: refresh))
            ]
        }
        sentWallpaperKey = nil
        sendWallpaperColor()
    }

    private func sendWallpaperColor() {
        guard let screen = window?.screen ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        guard key != sentWallpaperKey else { return }
        sentWallpaperKey = key
        Task { [weak self] in
            let color = await Task.detached(priority: .utility) { Self.wallpaperColor(at: url) }.value
            // An empty color tells the UI to fall back to the Space's own.
            self?.bridgeRouter.send(event: "wallpaperColorChanged", data: ["color": color ?? ""])
        }
    }

    nonisolated static func wallpaperColor(at url: URL) -> String? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return FaviconService.dominantColor(of: image)
    }
}
