// The wallpaper color a Space can follow, and its preview, read from the desktop picture of the window's screen.

import AppKit
import ImageIO
import UniformTypeIdentifiers

extension MainWindowController {
    /// The UI turns this on only while it shows a Space that follows the wallpaper or the color picker; enabling again resends it.
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
            let wallpaper = await Task.detached(priority: .utility) { Self.wallpaper(at: url) }.value
            // An empty color tells the UI to fall back to the Space's own.
            self?.bridgeRouter.send(event: "wallpaperColorChanged", data: [
                "color": wallpaper?.color ?? "", "thumbnail": wallpaper?.thumbnail ?? ""
            ])
        }
    }

    /// The picture's dominant color, and a small JPEG of it for the color picker's preview.
    nonisolated static func wallpaper(at url: URL) -> (color: String?, thumbnail: String)? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (FaviconService.dominantColor(of: image), "data:image/jpeg;base64,\((data as Data).base64EncodedString())")
    }
}
