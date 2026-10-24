import Foundation
import os

@MainActor
final class DownloadBridgeHandler: BridgeHandler {
    private static let logger = Logger(liloCategory: "DownloadManager")

    let handledActions: Set<String> = [
        "requestDownloadsSnapshot",
        "pauseDownload",
        "resumeDownload",
        "cancelDownload",
        "eraseDownload",
        "retryDownload",
        "openDownload",
        "showDownloadInFinder",
        "removeDownloadFile",
        "quickLookDownload",
        "startDownloadDrag",
        "showDownloadsFolder"
    ]

    private weak var downloadManager: DownloadManager?
    private weak var bridgeRouter: BridgeRouter?
    private let observerToken: UUID
    var onQuickLookRequested: (() -> Void)?
    var onDragRequested: ((URL) -> Void)?

    init(downloadManager: DownloadManager, bridgeRouter: BridgeRouter) {
        self.downloadManager = downloadManager
        self.bridgeRouter = bridgeRouter
        observerToken = downloadManager.addObserver { [weak bridgeRouter, weak downloadManager] item in
            let data = downloadManager?.augmentedBridgeData(for: item) ?? item.bridgeData
            bridgeRouter?.send(event: "downloadUpdated", data: data)
        }
    }

    // The manager outlives every window: the observer goes with the window's handler.
    nonisolated deinit {
        MainActor.assumeIsolated {
            downloadManager?.removeObserver(observerToken)
        }
    }

    func handle(message: BridgeMessage) async -> Any? {
        let id = message.int("id").map(Int64.init)
        switch message.action {

        case "requestDownloadsSnapshot":
            guard let items = try? downloadManager?.store?.fetchAll() else {
                bridgeRouter?.send(event: "downloadsSnapshot", data: ["items": []])
                return nil
            }
            let bridgeItems = items.map { item in
                downloadManager?.augmentedBridgeData(for: item) ?? item.bridgeData
            }
            bridgeRouter?.send(event: "downloadsSnapshot", data: ["items": bridgeItems])
            return nil

        case "pauseDownload":
            if let id { await downloadManager?.pause(id: id) }
            return nil

        case "resumeDownload":
            if let id { await downloadManager?.resume(id: id) }
            return nil

        case "cancelDownload":
            if let id { await downloadManager?.cancel(id: id) }
            return nil

        case "eraseDownload":
            if let id { loggingPersistenceError("download.erase[\(id)]") { try downloadManager?.erase(id: id) } }
            return nil

        case "retryDownload":
            guard let id else { return nil }
            do { try await downloadManager?.retryDownload(id: id) } catch {
                Self.logger.error("download retry failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil

        case "openDownload":
            if let id { downloadManager?.openFile(id: id) }
            return nil

        case "showDownloadInFinder":
            if let id { downloadManager?.showInFinder(id: id) }
            return nil

        case "removeDownloadFile":
            if let id { loggingPersistenceError("download.removeFile[\(id)]") { try downloadManager?.removeFile(id: id) } }
            return nil

        case "quickLookDownload":
            guard let id else { return nil }
            guard downloadManager?.prepareQuickLook(id: id) != nil else { return nil }
            onQuickLookRequested?()
            return nil

        case "startDownloadDrag":
            guard let id,
                  let url = downloadManager?.fileURL(id: id) else { return nil }
            onDragRequested?(url)
            return nil

        case "showDownloadsFolder":
            downloadManager?.showDownloadsFolder()
            return nil

        default:
            return nil
        }
    }
}
