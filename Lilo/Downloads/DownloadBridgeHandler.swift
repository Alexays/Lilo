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
    /// The store of the window's profile: the window lists that profile's downloads only.
    private let storeProvider: () -> DownloadStore?
    private let observerToken: UUID
    var onQuickLookRequested: (() -> Void)?
    var onDragRequested: ((URL) -> Void)?

    init(downloadManager: DownloadManager, bridgeRouter: BridgeRouter, storeProvider: @escaping () -> DownloadStore?) {
        self.downloadManager = downloadManager
        self.bridgeRouter = bridgeRouter
        self.storeProvider = storeProvider
        observerToken = downloadManager.addObserver { [weak bridgeRouter, weak downloadManager] item in
            guard let store = storeProvider(), item.profileId == store.profileId else { return }
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

    /// The `downloadsSnapshot` of a window showing `store`'s profile.
    static func snapshot(of store: DownloadStore?, manager: DownloadManager?) -> [String: Any] {
        let items = (try? store?.fetchAll()) ?? []
        return ["items": items.map { manager?.augmentedBridgeData(for: $0) ?? $0.bridgeData }]
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {
        case "requestDownloadsSnapshot":
            bridgeRouter?.send(event: "downloadsSnapshot", data: Self.snapshot(of: storeProvider(), manager: downloadManager))
            return nil
        case "showDownloadsFolder":
            downloadManager?.showDownloadsFolder()
            return nil
        default:
            break
        }
        guard let id = message.int("id").map(Int64.init), let store = storeProvider(), let downloadManager else { return nil }
        switch message.action {

        case "pauseDownload":
            await downloadManager.pause(id: id, in: store)

        case "resumeDownload":
            await downloadManager.resume(id: id, in: store)

        case "cancelDownload":
            await downloadManager.cancel(id: id, in: store)

        case "eraseDownload":
            loggingPersistenceError("download.erase[\(id)]") { try downloadManager.erase(id: id, in: store) }

        case "retryDownload":
            do { try await downloadManager.retryDownload(id: id, in: store) } catch {
                Self.logger.error("download retry failed: \(error.localizedDescription, privacy: .public)")
            }

        case "openDownload":
            downloadManager.openFile(id: id, in: store)

        case "showDownloadInFinder":
            downloadManager.showInFinder(id: id, in: store)

        case "removeDownloadFile":
            loggingPersistenceError("download.removeFile[\(id)]") { try downloadManager.removeFile(id: id, in: store) }

        case "quickLookDownload":
            guard downloadManager.prepareQuickLook(id: id, in: store) != nil else { return nil }
            onQuickLookRequested?()

        case "startDownloadDrag":
            guard let url = downloadManager.fileURL(id: id, in: store) else { return nil }
            onDragRequested?(url)

        default:
            break
        }
        return nil
    }
}
