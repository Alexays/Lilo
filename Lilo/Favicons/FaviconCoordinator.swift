import WebKit

/// Owns favicon resolution for tabs: cache hits, restored-tab cache warming, and loading the page's
/// link icons through WebKit with in-flight coalescing per host. The actual tab write is delegated
/// back via the `applyFavicon` closure (which routes through MainWindowController's runtime/store update).
@MainActor
final class FaviconCoordinator {
    private let service: FaviconService
    private let applyFavicon: (_ tabId: UUID, _ dataURL: String?, _ color: String?) -> Void
    private var inFlight: [String: Task<FaviconService.Resolved?, Never>] = [:]
    /// Hosts where no icon resolved, and when. Without it every page load there would re-request
    /// each icon (a 404 at least).
    private var failedAt: [String: Date] = [:]
    private static let failureRetryInterval: TimeInterval = 10 * 60

    init(service: FaviconService, applyFavicon: @escaping (UUID, String?, String?) -> Void) {
        self.service = service
        self.applyFavicon = applyFavicon
    }

    /// Show a cached favicon immediately if available, expired or not. Returns the icon shown.
    @discardableResult
    func applyCached(from tab: WKWebViewTab) -> FaviconService.Resolved? {
        guard let pageHost = tab.currentURL?.host?.lowercased(),
              let cached = service.cached(for: pageHost) else { return nil }
        applyFavicon(tab.id, cached.dataURL, cached.dominantColor)
        // Persistent data stores are keyed by profile id; ephemeral (private) ones have no identifier.
        if let profileId = tab.wkWebView.configuration.websiteDataStore.identifier {
            service.persistCachedIfUnwritten(host: pageHost, profileId: profileId)
        }
        return cached
    }

    /// Seed the favicon cache from already-known favicons (restored tabs) so navigating to
    /// these hosts doesn't re-download. Called when a space's tabs enter the runtime.
    func warm(from tabs: [Tab]) {
        for tab in tabs {
            guard let dataURL = tab.faviconDataURL, let host = tab.url?.host else { continue }
            service.warmIfAbsent(host: host, dataURL: dataURL, dominantColor: tab.faviconDominantColor)
        }
    }

    /// Resolves the favicon from the link icons WebKit offers for the loaded page: the cached one
    /// first, else the first icon that loads, smallest first among those declared big enough for the
    /// stored size, then undeclared ones (touch icons first), then smaller ones, largest first: a 512px
    /// icon costs tens of KB for a 32px thumbnail. Concurrent loads for one host are coalesced; the
    /// dominant color is computed once.
    func extract(from tab: WKWebViewTab, icons: [WKWebViewTab.LinkIcon]) {
        let shown = applyCached(from: tab)
        guard let pageHost = tab.currentURL?.host?.lowercased(), shown?.isExpired ?? true,
              failedAt[pageHost].map({ Date().timeIntervalSince($0) >= Self.failureRetryInterval }) ?? true,
              !icons.isEmpty else {
            icons.forEach { $0.decide(nil) }
            return
        }

        let tabId = tab.id
        // Persistent data stores are keyed by profile id; ephemeral (private) ones have no identifier.
        let profileId = tab.wkWebView.configuration.websiteDataStore.identifier
        let fetch: Task<FaviconService.Resolved?, Never>
        if let existing = inFlight[pageHost] {
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
                    if let data, !data.isEmpty { resolved = await Self.resolve(data) }
                }
                guard let self else { return nil }
                self.inFlight[pageHost] = nil
                guard let resolved else {
                    // Offline or a slow link is no verdict on the host: retry on its next page load.
                    guard NetworkPathStatus.shared.isSatisfied, !timedOut else { return nil }
                    let now = Date()
                    self.failedAt = self.failedAt.filter { now.timeIntervalSince($0.value) < Self.failureRetryInterval }
                    self.failedAt[pageHost] = now
                    return nil
                }
                self.failedAt[pageHost] = nil
                self.service.seed(host: pageHost, dataURL: resolved.dataURL, dominantColor: resolved.color, profileId: profileId)
                return FaviconService.Resolved(dataURL: resolved.dataURL, dominantColor: resolved.color)
            }
            inFlight[pageHost] = fetch
        }

        Task { @MainActor [weak self] in
            guard let resolved = await fetch.value, let self,
                  resolved.dataURL != shown?.dataURL || resolved.dominantColor != shown?.dominantColor else { return }
            self.applyFavicon(tabId, resolved.dataURL, resolved.dominantColor)
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
