import Foundation

/// Centralizes the Chrome User-Agent we present to the Chrome Web Store and the rules for
/// recognizing the store origin. The same UA downloads CRX3 packages from Google's update server,
/// so the store and the download speak to the same identity.
enum ChromeMasquerade {
    /// The Chrome product token Lilo claims.
    static let chromeApplicationName = "Chrome/155.0.0.0 Safari/537.36"
    /// Full Chrome desktop UA.
    static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) \(chromeApplicationName)"

    /// The canonical current store host. Used for the install-handler origin allowlist (which only
    /// has a host, no path).
    private static let storeHost = "chromewebstore.google.com"

    /// True for the current store host, or the legacy `chrome.google.com/webstore` path.
    static func isStoreURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == storeHost { return true }
        if host == "chrome.google.com" { return url.path.lowercased().hasPrefix("/webstore") }
        return false
    }

    /// True only for the current store host (origin allowlist for the native install transport).
    static func isStoreHost(_ host: String) -> Bool {
        host.lowercased() == storeHost
    }
}
