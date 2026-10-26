// Downloads setup, Quick Look, file drag.

import AppKit
import QuickLookUI
import WebKit

// MARK: - Downloads Setup

extension MainWindowController {
    func setupDownloads() {
        context.downloadManager.downloadsFolderProvider = { [weak context] in context?.settingsStore?.downloadsFolder }
        context.downloadManager.chooseDestination = { [weak context] proposed, webView, prompts in
            guard prompts || context?.settingsStore?.askDownloadLocation == true else { return proposed }
            // An agent's download lands in the folder: no panel over the user's window.
            if (webView?.uiDelegate as? WKWebViewTab)?.agentDialogHandler?("Download saved to \(proposed.path)") == true { return proposed }
            let panel = NSSavePanel()
            panel.directoryURL = proposed.deletingLastPathComponent()
            panel.nameFieldStringValue = proposed.lastPathComponent
            // On the window of the page that downloads, not whichever window is key.
            guard let window = webView?.window ?? NSApp.keyWindow else { return panel.runModal() == .OK ? panel.url : nil }
            return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
        }
        context.downloadManager.suggestFilename = { [weak context] item in
            guard let registry = item.profileId.flatMap({ context?.profileContexts.existingContext(for: $0)?.extensions }) else { return nil }
            return await DownloadsBridgeHandler.suggestFilename(for: item, registry: registry)
        }
        context.downloadManager.webView = tabManager.activeEngineTab?.wkWebView
    }
}

// MARK: - Quick Look

extension MainWindowController: QLPreviewPanelDataSource {

    func beginDownloadFileDrag(fileURL: URL) {
        guard let event = chromeLeftMouseEvent else { return }

        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        // setDraggingFrame expects the source view's coordinate space; the web view is
        // flipped, so window coordinates would mirror the y position (icon pops in from
        // the bottom of the panel instead of under the pointer).
        let loc = chromeWebView.convert(event.locationInWindow, from: nil)
        let size = NSSize(width: 32, height: 32)
        draggingItem.setDraggingFrame(
            NSRect(x: loc.x - size.width / 2, y: loc.y - size.height / 2,
                   width: size.width, height: size.height),
            contents: NSWorkspace.shared.icon(forFile: fileURL.path)
        )
        chromeWebView.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            context.downloadManager.quickLookItemURL != nil ? 1 : 0
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            context.downloadManager.quickLookItemURL as NSURL?
        }
    }
}

extension MainWindowController: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .every
    }
}
