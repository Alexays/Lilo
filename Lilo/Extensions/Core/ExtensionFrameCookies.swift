import OSLog
import WebKit

/// Sends a site framed by an extension page its first-party cookies, `SameSite=Lax` and `Strict` ones included, when the
/// extension may access it, as Chrome does; WebKit takes the frame for cross-site and leaves them out.
/// A rule list in the extension pages' content controller sets the `Cookie` header of what the extension's pages request
/// from that site, from the profile's store. It exists only while a page frames such a site, and follows the store until then.
@MainActor
final class ExtensionFrameCookies: NSObject, WKHTTPCookieStoreObserver {
    private struct Framer: Hashable {
        let site: String
        let extensionId: String
    }

    private static let logger = Logger(liloCategory: "extension-frame-cookies")

    private let identifier: String
    private let cookieStore: WKHTTPCookieStore
    private let userContentController: WKUserContentController
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
        guard !covered.contains(framer) else { return false }
        waiting.append(ready)
        if !observing {
            cookieStore.add(self)
            observing = true
        }
        build()
        return true
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        build()
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
                let source = sites.isEmpty ? "" : Self.rules(for: await cookieStore.allCookies(), framedBy: sites)
                await install(source)
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
        var rules: [[String: Any]] = []
        for cookie in cookies {
            let isDomain = cookie.domain.hasPrefix(".")
            let host = isDomain ? String(cookie.domain.dropFirst()) : cookie.domain
            guard let extensionIds = sites.first(where: { host == $0.key || host.hasSuffix("." + $0.key) })?.value else { continue }
            let origin = "^\(cookie.isSecure ? "https" : "https?")://\(isDomain ? "([^/:]+\\.)?" : "")\(escaped(host))(:[0-9]+)?"
            let path = cookie.path.isEmpty ? "/" : cookie.path
            // A path matches itself and what lies under it, never a sibling that only starts like it.
            let filters = path.hasSuffix("/") ? [origin + escaped(path)] : [origin + escaped(path) + "(\\?.*)?$", origin + escaped(path) + "/"]
            let action: [String: Any] = [
                "type": "modify-headers",
                "priority": 1,
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
}
