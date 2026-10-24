import Foundation

/// Handles screenshot-editor actions posted by the Svelte overlay. All side effects (disk write,
/// save panel, pasteboard, toast events) are injected so the routing/decoding contract is testable
/// without AppKit. Production wiring lives in `MainWindowController+Setup.setupBridgeLate()`.
@MainActor
final class ScreenshotBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = [
        "screenshot.saveDefault",
        "screenshot.saveAs",
        "screenshot.copy",
        "screenshot.cancel"
    ]

    private let downloadsFolderProvider: () -> URL
    /// Runs off the main thread.
    private let writeFile: @Sendable (Data, URL) throws -> Void
    /// Names picked by saves still writing, so two quick saves never pick the same file.
    private var reservedURLs: Set<URL> = []
    /// Presents a save panel for `data` and, on confirm, writes it and reports the path. Owns the whole flow so it can present a sheet
    /// asynchronously: a synchronous `runModal()` from the WebKit message context does not present reliably.
    private let presentSaveAs: (_ suggestedName: String, _ data: Data) -> Void
    private let copyToPasteboard: (Data) -> Void
    private let onSaved: (String) -> Void
    private let onError: (String) -> Void
    /// The PNG of a capture still open in the editor, by id.
    private let capture: (String) -> Data?
    private let discardCapture: (String) -> Void

    init(
        downloadsFolderProvider: @escaping () -> URL,
        writeFile: @escaping @Sendable (Data, URL) throws -> Void,
        presentSaveAs: @escaping (_ suggestedName: String, _ data: Data) -> Void,
        copyToPasteboard: @escaping (Data) -> Void,
        onSaved: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        capture: @escaping (String) -> Data?,
        discardCapture: @escaping (String) -> Void
    ) {
        self.downloadsFolderProvider = downloadsFolderProvider
        self.writeFile = writeFile
        self.presentSaveAs = presentSaveAs
        self.copyToPasteboard = copyToPasteboard
        self.onSaved = onSaved
        self.onError = onError
        self.capture = capture
        self.discardCapture = discardCapture
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {
        case "screenshot.cancel":
            message.string("id").map(discardCapture)
            return nil

        case "screenshot.copy":
            guard let data = await exported(message) else { return nil }
            copyToPasteboard(data)
            message.string("id").map(discardCapture)
            return nil

        case "screenshot.saveDefault":
            guard let data = await exported(message) else { return nil }
            let filename = message.string("filename", default: "screenshot.png")
            let folder = downloadsFolderProvider()
            let url = ScreenshotImageCodec.uniqueURL(in: folder, filename: filename) {
                reservedURLs.contains($0) || FileManager.default.fileExists(atPath: $0.path)
            }
            reservedURLs.insert(url)
            let writeFile = writeFile
            let written = await Task.detached(priority: .userInitiated) { Result { try writeFile(data, url) } }.value
            reservedURLs.remove(url)
            switch written {
            case .success:
                onSaved(url.path)
            case .failure(let error):
                onError(String(format: "Could not save the screenshot: %@".localized, error.localizedDescription))
                return nil
            }
            message.string("id").map(discardCapture)
            return nil

        case "screenshot.saveAs":
            // The capture stays held: cancelling the panel leaves the editor open on it.
            guard let data = await exported(message) else { return nil }
            let filename = message.string("filename", default: "screenshot.png")
            presentSaveAs(filename, data)
            return nil

        default:
            return nil
        }
    }

    /// The editor's flattened `dataURL` when it sent one, else the held capture `id` cut to `crop`.
    /// Reports an error toast (and returns nil) on failure. Decoding and re-encoding a multi-megabyte
    /// PNG runs off the main thread.
    private func exported(_ message: BridgeMessage) async -> Data? {
        if let dataURL = message.string("dataURL") {
            let data = await Task.detached(priority: .userInitiated) { ScreenshotImageCodec.decodePNGDataURL(dataURL) }.value
            if data == nil { onError("Could not decode the edited screenshot.".localized) }
            return data
        }
        guard let png = message.string("id").flatMap(capture) else {
            onError("The screenshot is no longer available.".localized)
            return nil
        }
        guard let crop = message.payload["crop"] as? [String: Double] else { return png }
        let rect = CGRect(x: crop["x"] ?? 0, y: crop["y"] ?? 0, width: crop["w"] ?? 0, height: crop["h"] ?? 0)
        let data = await Task.detached(priority: .userInitiated) { ScreenshotImageCodec.croppedPNG(png, to: rect) }.value
        if data == nil { onError("Could not crop the screenshot.".localized) }
        return data
    }
}
