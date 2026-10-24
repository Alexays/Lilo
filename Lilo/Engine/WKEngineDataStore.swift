import Foundation
import WebKit

final class WKEngineDataStore {
    let backingStore: WKWebsiteDataStore
    let identifier: String

    init(backingStore: WKWebsiteDataStore, identifier: String) {
        self.backingStore = backingStore
        self.identifier = identifier
    }

    @MainActor
    func removeAllData(modifiedSince date: Date) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await backingStore.removeData(ofTypes: types, modifiedSince: date)
    }

    @MainActor
    func removeCookies(modifiedSince date: Date) async {
        // WebKit's cookie date filter is coarse (per-origin record), the only time-scoped path available.
        await backingStore.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: date)
    }

    @MainActor
    func removeCache(modifiedSince date: Date) async {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache
        ]
        await backingStore.removeData(ofTypes: types, modifiedSince: date)
    }
}
