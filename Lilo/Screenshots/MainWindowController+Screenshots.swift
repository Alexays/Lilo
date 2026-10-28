// Page screenshot capture: copied, with a card that opens the editor on it or saves it.

import AppKit
import WebKit

extension MainWindowController {
    /// `url` is the captured tab's, not the active one's: the user may have switched tabs mid-capture.
    private func finishCapture(image: NSImage?, url: URL?) async {
        // Encoding a full-page capture takes seconds, so it stays off the main thread.
        let pixels = image?.snapshotPixels
        let png = await Task.detached(priority: .userInitiated) { pixels.flatMap(ScreenshotImageCodec.pngData) }.value
        guard let png else {
            bridgeRouter?.send(event: "screenshotError", data: ["message": "Could not capture the page.".localized])
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        let copy = ChromeUISchemeHandler.publishScreenshot(png)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let dateStr = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "screenshot-\(url?.host ?? "page")-\(dateStr).png"
        copiedCaptures[copy.id] = (copy.url, filename)
        bridgeRouter?.send(event: "captureCopied", data: [
            "captureId": copy.id,
            "thumbURL": copy.url.absoluteString,
            "filename": filename
        ])
    }

    /// The card's Edit: the editor opens on the copied capture, which it holds from then on.
    func editCopiedCapture(captureId: String) {
        guard let capture = copiedCaptures.removeValue(forKey: captureId) else { return }
        if let previous = screenshotCaptureId, previous != captureId { ChromeUISchemeHandler.discardScreenshot(id: previous) }
        screenshotCaptureId = captureId
        bridgeRouter?.send(event: "screenshotCaptured", data: [
            "id": captureId,
            "url": capture.image.absoluteString,
            "filename": capture.filename
        ])
    }

    /// The card of a copied capture is gone: nothing can open it any more.
    func releaseCopiedCapture(captureId: String) {
        guard copiedCaptures.removeValue(forKey: captureId) != nil else { return }
        ChromeUISchemeHandler.discardScreenshot(id: captureId)
    }

    @objc func takeFullPageScreenshot(_ sender: Any? = nil) {
        guard let engine = tabManager.activeEngineTab else { return }
        let url = engine.currentURL
        Task { @MainActor in
            let snapshot = await engine.takeFullPageSnapshot()
            await finishCapture(image: snapshot?.image, url: url)
        }
    }

    @objc func takeViewportScreenshot(_ sender: Any? = nil) {
        guard let engine = tabManager.activeEngineTab else { return }
        let url = engine.currentURL
        Task { @MainActor in await finishCapture(image: await engine.takeSnapshot(), url: url) }
    }

    @objc func startRegionSelection(_ sender: Any? = nil) {
        guard let engine = tabManager.activeEngineTab else { return }
        engine.startRegionSelection { [weak self] rect in
            guard let self, let rect else { return }
            let url = engine.currentURL
            Task { @MainActor in await self.finishCapture(image: await engine.takeRegionSnapshot(rect: rect), url: url) }
        }
    }
}
