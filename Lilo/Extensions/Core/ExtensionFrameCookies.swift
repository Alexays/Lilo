import OSLog
import WebKit

/// Sends a site framed by an extension page its first-party cookies, `SameSite=Lax` and `Strict` ones included, when the
/// extension may access it, as Chrome does; WebKit takes the frame for cross-site and leaves them out.
/// A rule list in the extension pages' content controller sets the `Cookie` header of what the extension's pages request
/// from that site, from the profile's store; WebKit applies no rule to a WebSocket handshake, which gets copies of the site's
/// `SameSite` cookies partitioned under the extension's pages instead. Both exist only while a page frames such a site, and
/// follow the store until then.
@MainActor
final class ExtensionFrameCookies: NSObject, WKHTTPCookieStoreObserver {
    private struct Framer: Hashable {
        let site: String
        let extensionId: String
    }

    private static let logger = Logger(liloCategory: "extension-frame-cookies")
    /// Tells Lilo's copies from the cookies a site sets in an extension page's partition itself.
    private static let copyComment = "lilo-extension-frame-copy"
    private static let partition = HTTPCookiePropertyKey("StoragePartition")

    private let identifier: String
    private let cookieStore: WKHTTPCookieStore
    private let userContentController: WKUserContentController
    private lazy var responseCookies = FrameResponseCookies(frameCookies: self)
    private lazy var ruleStore = WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true))
    private let hasAccess: (String, URL) -> Bool
    /// The extension pages framing each site, and the framers the installed rules cover.
    private var framers: [Framer: NSHashTable<WKWebView>] = [:]
    private var covered: Set<Framer> = []
    private var installed: (source: String, list: WKContentRuleList)?
    private var waiting: [() -> Void] = []
    /// Changes arriving while a build runs share the next one, as `CookieChangeTracker` reads.
    private var building = false
    private var stale = false
    private var observing = false

    init(profileId: UUID, cookieStore: WKHTTPCookieStore, userContentController: WKUserContentController, hasAccess: @escaping (String, URL) -> Bool) {
        identifier = Self.identifier(for: profileId)
        self.cookieStore = cookieStore
        self.userContentController = userContentController
        self.hasAccess = hasAccess
    }

    /// The rule list's identifier, which the extension pages' preferences must grant header changes to.
    static func identifier(for profileId: UUID) -> String {
        "lilo-extension-frame-cookies-\(profileId.uuidString)"
    }

    /// Whether `navigationAction` must wait for `ready`: an extension page frames a site it may access whose cookies
    /// its rules do not carry yet. `ready` runs once they do, or once building them failed.
    func waitsForCookies(of navigationAction: WKNavigationAction, in webView: WKWebView, ready: @escaping () -> Void) -> Bool {
        guard let frame = navigationAction.targetFrame, !frame.isMainFrame,
              let top = webView.url, top.scheme == "chrome-extension", let extensionId = top.host,
              let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty, hasAccess(extensionId, url) else { return false }
        let framer = Framer(site: CookiesBridgeHandler.registrableDomain(of: host), extensionId: extensionId)
        let pages = framers[framer] ?? .weakObjects()
        pages.add(webView)
        framers[framer] = pages
        keepCookies(of: webView)
        guard !covered.contains(framer) else { return false }
        waiting.append(ready)
        if !observing {
            cookieStore.add(self)
            observing = true
        }
        build()
        return true
    }

    /// Puts the frame cookies in front of the navigation delegate of an extension page Lilo does not drive: a popup, whose
    /// delegate is WebKit's, or an offscreen document. Called before its first navigation decision; once is enough.
    func watch(_ webView: WKWebView) {
        guard !(webView.navigationDelegate is FrameCookiesNavigationDelegate) else { return }
        let delegate = FrameCookiesNavigationDelegate(frameCookies: self, original: webView.navigationDelegate as? NSObject)
        // The web view holds its navigation delegate weakly.
        objc_setAssociatedObject(webView, &FrameCookiesNavigationDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.navigationDelegate = delegate
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        build()
    }

    /// WebKit drops what a frame it takes for cross-site sets, `Lax` cookies included, where Chrome keeps it: the page's
    /// responses go through WKWebView._setResourceLoadDelegate:, which sees their headers, unless the page has one already.
    private func keepCookies(of webView: WKWebView) {
        let setter = NSSelectorFromString("_setResourceLoadDelegate:"), getter = NSSelectorFromString("_resourceLoadDelegate")
        guard webView.responds(to: setter), webView.responds(to: getter), webView.perform(getter) == nil else { return }
        webView.perform(setter, with: responseCookies)
    }

    /// Stores the cookies a response from a framed site sets, as the site's own; partitioned ones belong to another top-level site.
    fileprivate func store(_ response: URLResponse, in webView: WKWebView) {
        guard let http = response as? HTTPURLResponse, let url = http.url, let header = http.value(forHTTPHeaderField: "Set-Cookie"),
              let host = url.host?.lowercased(), let top = webView.url, top.scheme == "chrome-extension", let extensionId = top.host,
              framers[Framer(site: CookiesBridgeHandler.registrableDomain(of: host), extensionId: extensionId)] != nil,
              hasAccess(extensionId, url) else { return }
        // The header joins the response's Set-Cookie lines with ", ": each starts with `name=`, unlike the rest of an Expires date.
        for line in header.split(separator: /,\s*(?=[!#$%&'*+\-.^_`|~0-9A-Za-z]+=)/)
        where line.range(of: #";\s*partitioned\s*(;|$)"#, options: [.regularExpression, .caseInsensitive]) == nil {
            HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": String(line)], for: url).forEach { cookieStore.setCookie($0) }
        }
    }

    private func build() {
        if building { stale = true; return }
        building = true
        Task {
            repeat {
                stale = false
                framers = framers.filter { $0.value.anyObject != nil }
                let framing = framers.keys
                let sites = Dictionary(grouping: framing, by: \.site).mapValues { Set($0.map(\.extensionId)) }
                let cookies = await cookieStore.allCookies()
                await syncCopies(of: cookies, for: sites)
                await install(sites.isEmpty ? "" : Self.rules(for: cookies, framedBy: sites))
                covered = Set(framing)
            } while stale
            building = false
            if framers.isEmpty, observing {
                cookieStore.remove(self)
                observing = false
            }
            let ready = waiting
            waiting = []
            ready.forEach { $0() }
        }
    }

    private func install(_ source: String) async {
        guard source != (installed?.source ?? "") else { return }
        guard !source.isEmpty, let ruleStore else {
            if let installed { userContentController.remove(installed.list) }
            installed = nil
            return
        }
        do {
            // A list under the same identifier replaces the installed one, so the frame is never left without cookies.
            guard let list = try await ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) else { return }
            userContentController.add(list)
            installed = (source, list)
            // The compiled file holds cookie values: the web processes keep their mapping, the disk keeps nothing.
            try? await ruleStore.removeContentRuleList(forIdentifier: identifier)
        } catch {
            Self.logger.error("frame cookie rules failed to compile: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A rule per cookie and path match appending the cookie to what the pages of the extensions framing its site request.
    /// A `Cookie` header set this way replaces WebKit's own, so every cookie of a framed site has its rules, not only the
    /// `SameSite` ones.
    private static func rules(for cookies: [HTTPCookie], framedBy sites: [String: Set<String>]) -> String {
        func created(_ cookie: HTTPCookie) -> Double { (cookie.properties?[HTTPCookiePropertyKey("Created")] as? NSNumber)?.doubleValue ?? 0 }
        // A partitioned cookie belongs to the top-level site it was set under, never to an extension page. The rest go in a
        // browser's order, longest path first then oldest, which WebKit keeps only through priorities.
        let sent = cookies
            .filter { ($0.properties?[HTTPCookiePropertyKey("StoragePartition")] as? String)?.isEmpty ?? true }
            .sorted { ($0.path.count, -created($0)) > ($1.path.count, -created($1)) }
        var rules: [[String: Any]] = []
        for (index, cookie) in sent.enumerated() {
            let isDomain = cookie.domain.hasPrefix(".")
            let host = isDomain ? String(cookie.domain.dropFirst()) : cookie.domain
            guard let extensionIds = sites.first(where: { host == $0.key || host.hasSuffix("." + $0.key) })?.value else { continue }
            let origin = "^\(cookie.isSecure ? "https" : "https?")://\(isDomain ? "([^/:]+\\.)?" : "")\(escaped(host))(:[0-9]+)?"
            let path = cookie.path.isEmpty ? "/" : cookie.path
            // A path matches itself and what lies under it, never a sibling that only starts like it.
            let filters = path.hasSuffix("/") ? [origin + escaped(path)] : [origin + escaped(path) + "(\\?.*)?$", origin + escaped(path) + "/"]
            let action: [String: Any] = [
                "type": "modify-headers",
                "priority": sent.count - index,
                "request-headers": [["header": "Cookie", "operation": "append", "value": "\(cookie.name)=\(cookie.value)"]]
            ]
            let pages = extensionIds.sorted().map { "^chrome-extension://\(escaped($0))/" }
            for filter in filters {
                rules.append(["trigger": ["url-filter": filter, "url-filter-is-case-sensitive": true, "if-top-url": pages], "action": action])
            }
        }
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules, options: .sortedKeys) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func escaped(_ literal: String) -> String {
        literal.reduce(into: "") { result, character in
            if "\\^$.|?*+()[]{}".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    /// Writes the copies the framing extensions need for WebSockets, and removes the others: a copy follows its cookie and
    /// goes with the last page framing its site. Only `SameSite` cookies need one, WebKit sends the rest itself, even under
    /// tracking prevention for a site the user interacted with; a partitioned cookie belongs to another top-level site. A twin the site set in an extension's partition while WebKit served it as a third
    /// party goes too, else the frame would send both (Cloudflare challenges two `cf_clearance`).
    private func syncCopies(of cookies: [HTTPCookie], for sites: [String: Set<String>]) async {
        func key(_ cookie: HTTPCookie) -> String {
            "\(cookie.name)\t\(cookie.domain)\t\(cookie.path)\t\(cookie.properties?[Self.partition] as? String ?? "")"
        }
        func site(of cookie: HTTPCookie) -> Set<String>? {
            let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return sites.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value
        }
        var wanted: [String: HTTPCookie] = [:]
        var twins: Set<String> = []
        for cookie in cookies where (cookie.properties?[Self.partition] as? String ?? "").isEmpty {
            guard let extensionIds = site(of: cookie), var properties = cookie.properties else { continue }
            guard cookie.sameSitePolicy == .sameSiteLax || cookie.sameSitePolicy == .sameSiteStrict else {
                extensionIds.forEach { twins.insert("\(cookie.name)\t\(cookie.domain)\t\(cookie.path)\tchrome-extension://\($0)") }
                continue
            }
            properties[.sameSitePolicy] = nil
            properties[.comment] = Self.copyComment
            for extensionId in extensionIds {
                properties[Self.partition] = "chrome-extension://\(extensionId)"
                if let copy = HTTPCookie(properties: properties) { wanted[key(copy)] = copy }
            }
        }
        for cookie in cookies where cookie.comment != Self.copyComment && twins.contains(key(cookie)) {
            await cookieStore.deleteCookie(cookie)
        }
        for cookie in cookies where cookie.comment == Self.copyComment {
            let copy = wanted[key(cookie)]
            if let copy, copy.value == cookie.value, copy.expiresDate == cookie.expiresDate, copy.isSecure == cookie.isSecure,
               copy.isHTTPOnly == cookie.isHTTPOnly {
                wanted[key(cookie)] = nil
            } else if copy == nil {
                await cookieStore.deleteCookie(cookie)
            }
        }
        for copy in wanted.values { await cookieStore.setCookie(copy) }
    }
}

/// Lets a frame wait for its cookies, then hands every navigation callback to the delegate it stands in front of.
@MainActor
private final class FrameCookiesNavigationDelegate: NSObject, WKNavigationDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private weak var frameCookies: ExtensionFrameCookies?
    nonisolated(unsafe) private weak var original: NSObject?

    init(frameCookies: ExtensionFrameCookies, original: NSObject?) {
        self.frameCookies = frameCookies
        self.original = original
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

    // The variant WebKit's popup delegate implements: the one with preferences would take precedence over it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let forward = { [original] in
            if (original as? WKNavigationDelegate)?.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler) == nil {
                decisionHandler(.allow)
            }
        }
        if frameCookies?.waitsForCookies(of: navigationAction, in: webView, ready: forward) == true { return }
        forward()
    }
}

/// Hands the responses of a page framing a site to the frame cookies, which keep what the site sets.
@MainActor
private final class FrameResponseCookies: NSObject {
    private weak var frameCookies: ExtensionFrameCookies?

    init(frameCookies: ExtensionFrameCookies) {
        self.frameCookies = frameCookies
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func resourceLoad(_ webView: WKWebView, resourceLoad: AnyObject, didReceiveResponse response: URLResponse) {
        frameCookies?.store(response, in: webView)
    }
}
