import Foundation

/// The user-chosen downloads folder, or the system Downloads directory as fallback.
@MainActor
func resolvedDownloadsFolder(_ settingsFolder: URL?) -> URL {
    settingsFolder ?? BuildIdentity.defaultDownloadsDirectory
}

/// Shared bookkeeping the download backends compose: in-flight items kept in memory so progress
/// ticks update bytes without re-reading/-writing SQLite; terminal/paused transitions write
/// through to the store. Drives onUpdated.
@MainActor
final class InFlightDownloads {
    weak var store: DownloadStore?
    var onUpdated: ((DownloadItem) -> Void)?

    /// Each item keeps the store it was inserted into: a profile switch must not redirect its writes.
    private var items: [Int64: (item: DownloadItem, store: DownloadStore?)] = [:]

    /// Registers a newly started (or resumed) download of the current store and notifies.
    func begin(_ id: Int64, _ item: DownloadItem) {
        items[id] = (item, store)
        onUpdated?(item)
    }

    /// Progress tick: bytes are updated in memory only; the row's bytes are written once, at
    /// the terminal or paused transition.
    func tick(_ id: Int64, bytesReceived: Int64, totalBytes: Int64) {
        guard var entry = items[id] else { return }
        entry.item.bytesReceived = bytesReceived
        entry.item.totalBytes = totalBytes > 0 ? totalBytes : -1
        items[id] = entry
        onUpdated?(entry.item)
    }

    /// Terminal or paused transition: pull the item (memory first, store fallback), apply
    /// `mutate`, drop it from the in-flight set, persist, and notify. `mutate` returning false
    /// aborts with no side effects (a late callback racing an earlier transition).
    @discardableResult
    func settle(_ id: Int64, _ mutate: (inout DownloadItem) -> Bool) -> DownloadItem? {
        let entry = items[id]
        guard var item = entry?.item ?? (try? store?.fetch(id: id)) else { return nil }
        guard mutate(&item) else { return nil }
        items.removeValue(forKey: id)
        let itemStore = entry?.store ?? store
        loggingPersistenceError("download.update[\(id)]") {
            try itemStore?.update(item)
        }
        onUpdated?(item)
        return item
    }
}
