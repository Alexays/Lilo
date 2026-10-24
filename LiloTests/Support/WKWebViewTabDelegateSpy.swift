import WebKit
@testable import Lilo

/// Records the tab callbacks tests assert on; every other requirement is a no-op.
@MainActor
final class WKWebViewTabDelegateSpy: WKWebViewTab.Delegate {
    private(set) var updatedURLs: [URL?] = []
    private(set) var foregroundRequests = 0
    private(set) var commits = 0
    var onUpdateURL: ((URL?) -> Void)?

    func tab(_ tab: WKWebViewTab, didNavigate event: WKWebViewTab.WebNavigationEvent) {
        if case .committed = event { commits += 1 }
    }
    func tab(_ tab: WKWebViewTab, didUpdateTitle title: String?) {}
    func tab(_ tab: WKWebViewTab, didUpdateURL url: URL?) {
        updatedURLs.append(url)
        onUpdateURL?(url)
    }
    func tab(_ tab: WKWebViewTab, didUpdateLoading isLoading: Bool) {}
    func tab(_ tab: WKWebViewTab, didUpdateProgress progress: Double) {}
    func tab(_ tab: WKWebViewTab, didUpdateCanGoBack canGoBack: Bool) {}
    func tab(_ tab: WKWebViewTab, didUpdateCanGoForward canGoForward: Bool) {}
    func tab(_ tab: WKWebViewTab, didCreateNewTab url: URL?, inBackground: Bool) {}
    func tabDidRequestClose(_ tab: WKWebViewTab) {}
    func tab(_ tab: WKWebViewTab, didStartDownload download: WKDownload) {}
    func tab(
        _ tab: WKWebViewTab,
        requestPermission type: String,
        forOrigin origin: String,
        completion: @escaping (Bool) -> Void
    ) {}
    func tab(_ tab: WKWebViewTab, didUpdatePermissionUsage usage: WKWebViewTab.WebPermissionUsageState) {}
    func tabRequestsForeground(_ tab: WKWebViewTab) { foregroundRequests += 1 }
}
