import WebKit

/// Rebuilds the details of `chrome.cookies.onChanged`, which WebKit fires without them
/// (webkit.org/b/267514): diffs the profile's cookies after each store change and reports every
/// cookie added, overwritten or removed, as Chrome does.
@MainActor
final class CookieChangeTracker: NSObject, WKHTTPCookieStoreObserver {
    struct Change {
        let cookie: HTTPCookie
        let removed: Bool
        let cause: String

        /// Chrome's `changeInfo`, with the cookie in the shape WebKit's `cookies.get` returns. The
        /// page side adds `storeId`, which only WebKit knows.
        var changeInfo: [String: Any] {
            var details: [String: Any] = [
                "domain": cookie.domain,
                "hostOnly": !cookie.domain.hasPrefix("."),
                "httpOnly": cookie.isHTTPOnly,
                "name": cookie.name,
                "path": cookie.path,
                "sameSite": cookie.sameSitePolicy == .sameSiteLax ? "lax" : cookie.sameSitePolicy == .sameSiteStrict ? "strict" : "no_restriction",
                "secure": cookie.isSecure,
                "session": cookie.isSessionOnly,
                "value": cookie.value
            ]
            if let expires = cookie.expiresDate { details["expirationDate"] = expires.timeIntervalSince1970 }
            return ["cookie": details, "removed": removed, "cause": cause]
        }

        /// The origin Chrome checks host permissions against: the cookie's domain, without its dot.
        var originURL: URL? {
            let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return URL(string: "\(cookie.isSecure ? "https" : "http")://\(host)/")
        }
    }

    private struct Key: Hashable {
        let name: String
        let domain: String
        let path: String
    }

    private let store: WKHTTPCookieStore
    private let report: ([Change]) -> Void
    /// The store as of the last read; nil until the first read, which only takes the baseline.
    private var cookies: [Key: HTTPCookie]?
    /// Changes arriving while a read runs share the next one, so a page load's burst of Set-Cookie
    /// headers costs a couple of reads, while changes an extension makes one after another each show.
    private var reading = false
    /// The store changed after the running read began: it reads again once done.
    private var stale = false
    private var stopped = false
    private var current: Task<Void, Never>?

    init(store: WKHTTPCookieStore, report: @escaping ([Change]) -> Void) {
        self.store = store
        self.report = report
        super.init()
        store.add(self)
        read()
    }

    /// Returns once a read that began after this call is done: the changes made before it are reported,
    /// each apart from those that come after, as Chrome reports changes an extension makes one by one.
    func catchUp() async {
        cookiesDidChange(in: store)
        await current?.value
    }

    func stop() {
        stopped = true
        store.remove(self)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        if reading { stale = true } else { read() }
    }

    private func read() {
        reading = true
        current = Task {
            repeat {
                stale = false
                apply(await store.allCookies())
            } while stale && !stopped
            reading = false
        }
    }

    private func apply(_ all: [HTTPCookie]) {
        var current: [Key: HTTPCookie] = [:]
        current.reserveCapacity(all.count)
        for cookie in all { current[Key(name: cookie.name, domain: cookie.domain, path: cookie.path)] = cookie }
        defer { cookies = current }
        guard let previous = cookies, !stopped else { return }

        var changes: [Change] = []
        let now = Date()
        for (key, old) in previous {
            guard let new = current[key] else {
                let expired = old.expiresDate.map { $0 <= now } ?? false
                changes.append(Change(cookie: old, removed: true, cause: expired ? "expired" : "explicit"))
                continue
            }
            if old.value != new.value || old.expiresDate != new.expiresDate || old.isSecure != new.isSecure
                || old.isHTTPOnly != new.isHTTPOnly || old.sameSitePolicy != new.sameSitePolicy {
                changes.append(Change(cookie: old, removed: true, cause: "overwrite"))
                changes.append(Change(cookie: new, removed: false, cause: "explicit"))
            }
        }
        for (key, new) in current where previous[key] == nil {
            changes.append(Change(cookie: new, removed: false, cause: "explicit"))
        }
        if !changes.isEmpty { report(changes) }
    }
}
