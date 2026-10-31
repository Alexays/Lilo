import Foundation
import WebKit

final class WKEngineDataStore {
    let backingStore: WKWebsiteDataStore
    let identifier: String

    init(backingStore: WKWebsiteDataStore, identifier: String) {
        self.backingStore = backingStore
        self.identifier = identifier
    }

    /// Every type a site keeps in the store. Screen Time's history lives in its own service, which each fetch waits on
    /// (half a second, minutes on a loaded Mac), and Lilo reports to it without a store profile, so it holds none of the store's.
    @MainActor static let siteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes().subtracting([WKWebsiteDataTypeScreenTime])

    /// HTTP sign-ins WebKit keeps for the session, private and so missing from `allWebsiteDataTypes()`; WebKit ignores a type it does not know.
    private static let credentialsType = "_WKWebsiteDataTypeCredentials"

    @MainActor
    func removeAllData(modifiedSince date: Date) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes().union([Self.credentialsType])
        removeSavedHTTPCredentials(modifiedSince: date)
        await backingStore.removeData(ofTypes: types, modifiedSince: date)
    }

    @MainActor
    func removeCookies(modifiedSince date: Date) async {
        removeSavedHTTPCredentials(modifiedSince: date)
        // WebKit's cookie date filter is coarse (per-origin record), the only time-scoped path available.
        await backingStore.removeData(ofTypes: [WKWebsiteDataTypeCookies, Self.credentialsType], modifiedSince: date)
    }

    /// Like Chrome, a sign-in goes with the cookies: a remembered HTTP password belongs to the profile, the store's identifier.
    @MainActor
    private func removeSavedHTTPCredentials(modifiedSince date: Date) {
        guard let profileId = backingStore.identifier else { return }
        HTTPAuthKeychain.deleteAll(profileId: profileId, modifiedSince: date)
    }

    @MainActor
    func removeCache(modifiedSince date: Date) async {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache
        ]
        await backingStore.removeData(ofTypes: types, modifiedSince: date)
    }

    private typealias FetchRecords = @convention(c) (AnyObject, Selector, NSSet, UInt, @escaping @convention(block) (NSArray) -> Void) -> Void
    private typealias SizeOfTypes = @convention(c) (AnyObject, Selector, NSSet) -> UInt64

    /// Bytes stored per WebKit data type over every site, through WebKit's private size fetch; nil when WebKit no longer offers it.
    @MainActor
    func dataSizes() async -> [String: Int64]? {
        let fetch = NSSelectorFromString("_fetchDataRecordsOfTypes:withOptions:completionHandler:")
        let sizeOf = NSSelectorFromString("sizeOfDataTypes:")
        guard backingStore.responds(to: fetch) else { return nil }
        let types = Self.siteDataTypes
        // 1 is _WKWebsiteDataStoreFetchOptionComputeSizes. The records are summed where they arrive: they are not Sendable.
        return await withCheckedContinuation { continuation in
            unsafeBitCast(backingStore.method(for: fetch), to: FetchRecords.self)(backingStore, fetch, types as NSSet, 1) { records in
                var sizes: [String: Int64] = [:]
                for case let record as WKWebsiteDataRecord in records {
                    guard let size = record.value(forKey: "_dataSize") as? NSObject, size.responds(to: sizeOf) else { continue }
                    let sizeOfTypes = unsafeBitCast(size.method(for: sizeOf), to: SizeOfTypes.self)
                    for type in record.dataTypes {
                        sizes[type, default: 0] += Int64(sizeOfTypes(size, sizeOf, [type] as NSSet))
                    }
                }
                continuation.resume(returning: sizes)
            }
        }
    }
}
