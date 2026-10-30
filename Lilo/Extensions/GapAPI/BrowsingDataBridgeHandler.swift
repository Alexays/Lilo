import Foundation
import WebKit

/// chrome.browsingData.remove: site data on the profile's WKWebsiteDataStore, history and downloads on
/// Lilo's own stores. The per-type remove* calls and `settings` are shaped in JS.
@MainActor
final class BrowsingDataBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["browsingData.remove"]

    /// WebKit's data types behind each of Chrome's site data types; formData is WebKit's search field history.
    private static let websiteDataTypes: [String: Set<String>] = [
        "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
        "cacheStorage": [WKWebsiteDataTypeFetchCache],
        "cookies": [WKWebsiteDataTypeCookies],
        "fileSystems": [WKWebsiteDataTypeFileSystem],
        "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases],
        "localStorage": [WKWebsiteDataTypeLocalStorage],
        "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
        "formData": [WKWebsiteDataTypeSearchFieldRecentSearches]
    ]
    /// Chrome filters only site data and the cache by origin.
    private static let filterable: Set<String> = ["cache", "cacheStorage", "cookies", "fileSystems", "indexedDB", "localStorage", "serviceWorkers"]

    private let contextProvider: (ProfileExtensionRegistry) -> ProfileContext?
    private let downloadManagerProvider: () -> DownloadManager?

    init(contextProvider: @escaping (ProfileExtensionRegistry) -> ProfileContext?, downloadManagerProvider: @escaping () -> DownloadManager?) {
        self.contextProvider = contextProvider
        self.downloadManagerProvider = downloadManagerProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let profile = contextProvider(call.registry) else { return BridgeError("Browsing data unavailable") }
        let options = call.payload["options"] as? [String: Any] ?? [:]
        // Chrome ignores the types it no longer supports (appcache, pluginData, webSQL...).
        let selected = Set((call.payload["dataToRemove"] as? [String: Any] ?? [:]).compactMap { $0.value as? Bool == true ? $0.key : nil })
        let origins = options["origins"] as? [String]
        let excludeOrigins = options["excludeOrigins"] as? [String]
        if origins != nil && excludeOrigins != nil { return BridgeError("Don't set both 'origins' and 'excludeOrigins' at the same time.") }
        var hosts: [String] = []
        for origin in origins ?? excludeOrigins ?? [] {
            guard let url = URL(string: origin), url.scheme != nil, let host = url.host, !host.isEmpty else {
                return BridgeError("'\(origin)' is not a valid origin.")
            }
            hosts.append(host.lowercased())
        }
        let siteTypes = selected.intersection(Self.websiteDataTypes.keys)
        if !hosts.isEmpty && !selected.intersection(Self.websiteDataTypes.keys + ["history", "downloads"]).isSubset(of: Self.filterable) {
            return BridgeError("At least one data type doesn't support filtering by origin.")
        }
        let sinceMs = (options["since"] as? Double) ?? 0
        let since = Date(timeIntervalSince1970: sinceMs / 1000)
        let originTypes = options["originTypes"] as? [String: Any]

        // Chrome's default is unprotectedWeb alone; a given `originTypes` counts only its true keys. protectedWeb
        // (hosted apps) names nothing in Lilo, and WebKit cannot single out extension pages' data.
        if !siteTypes.isEmpty, originTypes == nil || originTypes?["unprotectedWeb"] as? Bool == true,
           let store = call.registry.controller.configuration.defaultWebsiteDataStore {
            let types = siteTypes.reduce(into: Set<String>()) { $0.formUnion(Self.websiteDataTypes[$1]!) }
            // Records list http(s) and file sites only, so going through them spares extension pages'
            // own data as Chrome does; WebKit cannot also bound them by time.
            if !hosts.isEmpty || (sinceMs <= 0 && originTypes?["extension"] as? Bool != true) {
                let records = await store.dataRecords(ofTypes: types).filter { record in
                    let site = record.displayName.lowercased()
                    let named = hosts.contains { $0 == site || $0.hasSuffix(".\(site)") }
                    return hosts.isEmpty || (origins != nil ? named : !named)
                }
                // WebKit's record removal can take every cookie of the store, so cookies go one by one.
                var recordTypes = types
                if recordTypes.remove(WKWebsiteDataTypeCookies) != nil {
                    let sites = Set(records.map { $0.displayName.lowercased() })
                    for cookie in await store.httpCookieStore.allCookies() {
                        let domain = cookie.domain.lowercased().drop { $0 == "." }
                        if sites.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") }) { await store.httpCookieStore.deleteCookie(cookie) }
                    }
                }
                if !records.isEmpty, !recordTypes.isEmpty { await store.removeData(ofTypes: recordTypes, for: records) }
            } else {
                await store.removeData(ofTypes: types, modifiedSince: since)
            }
        }

        if selected.contains("history") {
            let history = profile.history
            let removed = await Task.detached { () throws in
                if sinceMs <= 0 { try history.clearAll() } else { try history.deleteEntries(since: since) }
            }.result
            if case .failure(let error) = removed { return BridgeError(error.localizedDescription) }
        }

        if selected.contains("downloads"), let manager = downloadManagerProvider() {
            let downloads = profile.downloads
            let items = (try? await Task.detached { try downloads.search(limit: .max) }.value) ?? []
            for item in items where item.startedAt >= since && item.state != .inProgress {
                guard let id = item.id, !manager.isPrivateDownload(id: id, profileId: downloads.profileId) else { continue }
                try? manager.erase(id: id, in: downloads)
            }
        }
        return nil
    }
}
