import WebKit

/// Owns favicon resolution for tabs: cache hits, restored-tab cache warming, and loading the page's
/// link icons through WebKit with in-flight coalescing per data store and host. The tab write is delegated
/// back via the `applyFavicon` closure (which routes through MainWindowController's runtime/store update).
@MainActor
final class FaviconCoordinator {
    private let service: FaviconService
    private let applyFavicon: (_ tabId: UUID, _ dataURL: String?, _ color: String?, _ iconURL: URL?) -> Void
    private let privateSpaceId: (WKWebsiteDataStore) -> UUID?
    private var inFlight: [FaviconService.Key: Task<FaviconService.Resolved?, Never>] = [:]
    /// Hosts where no icon resolved, and when. Without it every page load there would re-request
    /// each icon (a 404 at least).
    private var failedAt: [FaviconService.Key: Date] = [:]
    private static let failureRetryInterval: TimeInterval = 10 * 60

    init(service: FaviconService, privateSpaceId: @escaping (WKWebsiteDataStore) -> UUID?,
         applyFavicon: @escaping (UUID, String?, String?, URL?) -> Void) {
        self.service = service
        self.privateSpaceId = privateSpaceId
        self.applyFavicon = applyFavicon
    }

    /// The cache partition of the tab's data store: the profile id a persistent store goes by, else the
    /// private space owning the ephemeral one. Nil for a store neither owns, whose tab gets no icon.
    private func partition(of tab: WKWebViewTab) -> UUID? {
        let store = tab.wkWebView.configuration.websiteDataStore
        return store.identifier ?? privateSpaceId(store)
    }

    /// Show a cached favicon immediately if available, expired or not. Returns the icon shown.
    @discardableResult
    func applyCached(from tab: WKWebViewTab) -> FaviconService.Resolved? {
        guard let pageHost = tab.currentURL?.faviconKey, let partition = partition(of: tab),
              let cached = service.cached(for: pageHost, partition: partition) else { return nil }
        applyFavicon(tab.id, cached.dataURL, cached.dominantColor, cached.iconURL.flatMap(URL.init(string:)))
        service.persistCachedIfUnwritten(host: pageHost, partition: partition)
        return cached
    }

    /// Seed the favicon cache from already-known favicons (restored tabs) so navigating to
    /// these hosts doesn't re-download. Called when a space's tabs enter the runtime.
    func warm(from tabs: [Tab], partition: UUID) {
        for tab in tabs {
            guard let dataURL = tab.faviconDataURL, let host = tab.url?.faviconKey else { continue }
            service.warmIfAbsent(host: host, dataURL: dataURL, dominantColor: tab.faviconDominantColor, partition: partition)
        }
    }

    /// Resolves the favicon from the link icons WebKit offers for the loaded page: the cached one
    /// first, else the first icon that loads, smallest first among those declared big enough for the
    /// stored size, then undeclared ones (touch icons first), then smaller ones, largest first: a 512px
    /// icon costs tens of KB for a 32px thumbnail. Concurrent loads for one host are coalesced; the
    /// dominant color is computed once.
    func extract(from tab: WKWebViewTab, icons: [WKWebViewTab.LinkIcon]) {
        let shown = applyCached(from: tab)
        // A site can switch icons on the same host (after signing in, say): an icon the page no
        // longer offers is refetched before its TTL runs out.
        let offered = shown?.iconURL.map { url in icons.contains { $0.url.absoluteString == url } } ?? false
        let key = tab.currentURL?.faviconKey.flatMap { host in partition(of: tab).map { FaviconService.Key(partition: $0, host: host) } }
        guard let key, (shown?.isExpired ?? true) || !offered,
              failedAt[key].map({ Date().timeIntervalSince($0) >= Self.failureRetryInterval }) ?? true,
              !icons.isEmpty else {
            icons.forEach { $0.decide(nil) }
            return
        }

        let tabId = tab.id
        let fetch: Task<FaviconService.Resolved?, Never>
        if let existing = inFlight[key] {
            icons.forEach { $0.decide(nil) }
            fetch = existing
        } else {
            let wanted = FaviconService.maxFaviconPixels
            let ranked = icons.enumerated().sorted { a, b in
                let (sa, sb) = (a.element.size, b.element.size)
                let (tierA, tierB) = (sa >= wanted ? 0 : sa == 0 ? 1 : 2, sb >= wanted ? 0 : sb == 0 ? 1 : 2)
                if tierA != tierB { return tierA < tierB }
                if sa != sb { return tierA == 0 ? sa < sb : sa > sb }
                if a.element.isTouchIcon != b.element.isTouchIcon { return a.element.isTouchIcon }
                return a.offset < b.offset
            }.map(\.element)
            fetch = Task { @MainActor [weak self] in
                var resolved: (dataURL: String, color: String?)?
                var resolvedURL: URL?
                var timedOut = false
                // WebKit may drop a load's callback: past this, the host stops waiting and moves on.
                let deadline = ContinuousClock.now + .seconds(10)
                for icon in ranked {
                    guard resolved == nil else { icon.decide(nil); continue }
                    let (stream, delivery) = AsyncStream.makeStream(of: Data?.self)
                    icon.decide { delivery.yield($0); delivery.finish() }
                    let timeout = Task { try? await Task.sleep(until: deadline); delivery.finish() }
                    var received = stream.makeAsyncIterator()
                    let data = await received.next() ?? nil
                    timeout.cancel()
                    if data == nil, ContinuousClock.now >= deadline { timedOut = true }
                    if let data, !data.isEmpty {
                        resolved = await Self.resolve(data)
                        resolvedURL = icon.url
                    }
                }
                guard let self else { return nil }
                self.inFlight[key] = nil
                guard let resolved else {
                    // Offline or a slow link is no verdict on the host: retry on its next page load.
                    guard NetworkPathStatus.shared.isSatisfied, !timedOut else { return nil }
                    let now = Date()
                    self.failedAt = self.failedAt.filter { now.timeIntervalSince($0.value) < Self.failureRetryInterval }
                    self.failedAt[key] = now
                    return nil
                }
                self.failedAt[key] = nil
                self.service.seed(host: key.host, dataURL: resolved.dataURL, dominantColor: resolved.color, iconURL: resolvedURL?.absoluteString, partition: key.partition)
                return FaviconService.Resolved(dataURL: resolved.dataURL, dominantColor: resolved.color, iconURL: resolvedURL?.absoluteString)
            }
            inFlight[key] = fetch
        }

        Task { @MainActor [weak self, weak tab] in
            // The tab may have moved to another host while the icon loaded: the cache keeps it, the tab does not.
            guard let resolved = await fetch.value, let self, tab?.currentURL?.faviconKey == key.host,
                  resolved.dataURL != shown?.dataURL || resolved.dominantColor != shown?.dominantColor || resolved.iconURL != shown?.iconURL else { return }
            self.applyFavicon(tabId, resolved.dataURL, resolved.dominantColor, resolved.iconURL.flatMap(URL.init(string:)))
        }
    }

    /// Decode, 32px thumbnail, PNG re-encode, base64 and dominant color run detached: ms-class for
    /// big .ico files. Only the cache seed returns to MainActor.
    private static func resolve(_ data: Data) async -> (dataURL: String, color: String?)? {
        await Task.detached(priority: .utility) { () -> (String, String?)? in
            guard let icon = FaviconService.encodedFavicon(data: data) else { return nil }
            let color: String?
            if let png = icon.png {
                color = FaviconService.dominantColor(fromPNG: png)
            } else {
                color = FaviconService.dominantColor(from: icon.dataURL)
            }
            return (icon.dataURL, color)
        }.value
    }
}
