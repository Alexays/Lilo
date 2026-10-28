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

    private struct Entry {
        var cookie: HTTPCookie
        /// The hash of the fields an overwrite may change, compared instead of the fields themselves.
        var fingerprint: Int
        /// The read that last found the cookie.
        var read: Int
    }

    /// The store as of the last read, updated in place off the main actor; the first read only takes the baseline.
    private actor Snapshot {
        private var cookies: [Key: Entry] = [:]
        private var reads = 0

        /// What changed since the last read.
        func diff(_ all: [HTTPCookie]) -> [Change] {
            reads += 1
            let reporting = reads > 1
            var changes: [Change] = []
            var found = 0
            for cookie in all {
                var hasher = Hasher()
                hasher.combine(cookie.value)
                hasher.combine(cookie.expiresDate)
                hasher.combine(cookie.isSecure)
                hasher.combine(cookie.isHTTPOnly)
                hasher.combine(cookie.sameSitePolicy)
                let fingerprint = hasher.finalize()
                let key = Key(name: cookie.name, domain: cookie.domain, path: cookie.path)
                guard let index = cookies.index(forKey: key) else {
                    cookies[key] = Entry(cookie: cookie, fingerprint: fingerprint, read: reads)
                    found += 1
                    if reporting { changes.append(Change(cookie: cookie, removed: false, cause: "explicit")) }
                    continue
                }
                let old = cookies.values[index]
                if old.read != reads { found += 1 }
                cookies.values[index].read = reads
                guard old.fingerprint != fingerprint else { continue }
                cookies.values[index].cookie = cookie
                cookies.values[index].fingerprint = fingerprint
                if reporting {
                    changes.append(Change(cookie: old.cookie, removed: true, cause: "overwrite"))
                    changes.append(Change(cookie: cookie, removed: false, cause: "explicit"))
                }
            }
            if cookies.count > found {
                let now = Date()
                let gone = cookies.filter { $0.value.read != reads }
                for (key, entry) in gone {
                    cookies.removeValue(forKey: key)
                    guard reporting else { continue }
                    let expired = entry.cookie.expiresDate.map { $0 <= now } ?? false
                    changes.append(Change(cookie: entry.cookie, removed: true, cause: expired ? "expired" : "explicit"))
                }
            }
            return changes
        }
    }

    private let store: WKHTTPCookieStore
    private let report: ([Change]) -> Void
    private let snapshot = Snapshot()
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
                let all = await store.allCookies()
                let changes = await snapshot.diff(all)
                if !changes.isEmpty, !stopped { report(changes) }
            } while stale && !stopped
            reading = false
        }
    }
}
