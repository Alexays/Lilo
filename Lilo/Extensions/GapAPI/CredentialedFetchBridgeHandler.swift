import Foundation
import WebKit

/// An extension's `fetch` with `credentials: "include"` to a host it may access, sent with every cookie of the
/// profile for that URL as Chrome sends them. WebKit treats an extension origin as another site, so it leaves out
/// `SameSite=Lax` and `Strict` cookies (WEBKIT-GAPS.md, gap 81): signed-in sessions (ChatGPT's) read as signed out.
/// Answers nil for a request WebKit sends as Chrome does, which the page then sends itself.
@MainActor
final class CredentialedFetchBridgeHandler: NSObject, GapHandler, URLSessionTaskDelegate {
    let gapActions: Set<String> = ["fetch.credentialed"]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func handle(_ call: GapCall) async -> Any? {
        guard let context = call.context,
              var url = call.string("url").flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              context.hasAccess(to: url) else { return nil }
        let store = WKWebsiteDataStore(forIdentifier: call.registry.profileId).httpCookieStore
        var method = call.string("method") ?? "GET"
        var body = call.string("body").flatMap { Data(base64Encoded: $0) }
        var headers = (call.payload["headers"] as? [[String]] ?? []).filter { $0.count == 2 }
        let origin = "\(context.baseURL.scheme ?? "")://\(context.baseURL.host ?? "")"
        // The profile's jar, read once over XPC and kept current with what each hop sets.
        var jar: [HTTPCookie]?
        // As fetch: at most 20 redirects, each hop with the cookies of its own URL.
        for hop in 0...20 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.httpShouldHandleCookies = false
            for header in headers where header[0].lowercased() != "cookie" { request.addValue(header[1], forHTTPHeaderField: header[0]) }
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if context.hasAccess(to: url) {
                if jar == nil { jar = await store.allCookies() }
                for (name, value) in HTTPCookie.requestHeaderFields(with: await store.cookies(for: url, in: jar)) { request.setValue(value, forHTTPHeaderField: name) }
            }
            let data: Data
            let response: HTTPURLResponse
            do {
                let (received, answer) = try await session.data(for: request, delegate: self)
                guard let http = answer as? HTTPURLResponse else { return BridgeError("Failed to fetch") }
                (data, response) = (received, http)
            } catch {
                return BridgeError("Failed to fetch")
            }
            let fields = response.allHeaderFields.reduce(into: [String: String]()) { fields, entry in
                if let name = entry.key as? String, let value = entry.value as? String { fields[name] = value }
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
                await store.setCookie(cookie)
                jar?.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                jar?.append(cookie)
            }
            if (300...399).contains(response.statusCode), response.statusCode != 304,
               let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
                if call.string("redirect") == "error" || hop == 20 { return BridgeError("Failed to fetch") }
                // A 303, or a 301 or 302 of a POST, goes on as a GET without a body.
                if response.statusCode == 303 || ([301, 302].contains(response.statusCode) && method == "POST") {
                    method = method == "HEAD" ? "HEAD" : "GET"
                    body = nil
                }
                // As fetch, a hop to another origin drops Authorization for the rest of the chain.
                if next.scheme?.lowercased() != url.scheme?.lowercased() || next.host?.lowercased() != url.host?.lowercased() || next.port != url.port {
                    headers.removeAll { $0[0].lowercased() == "authorization" }
                }
                url = next
                continue
            }
            return [
                "status": response.statusCode,
                "headers": fields.filter { $0.key.lowercased() != "set-cookie" }.map { [$0.key, $0.value] },
                "body": data.base64EncodedString(),
                "url": url.absoluteString,
                "redirected": hop > 0
            ] as [String: Any]
        }
        return BridgeError("Failed to fetch")
    }

    /// Redirects come back to `handle`, which sends each hop with its own cookies.
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension WKHTTPCookieStore {
    /// The cookies a request to `url` carries, whatever its initiator: domain, path, `Secure` and expiry match.
    /// Taken from `jar` when given, the store's whole jar otherwise.
    func cookies(for url: URL, in jar: [HTTPCookie]? = nil) async -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        let now = Date()
        let cookies: [HTTPCookie]
        if let jar { cookies = jar } else { cookies = await allCookies() }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let domainMatches = domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
            return domainMatches && path.hasPrefix(cookie.path) && (!cookie.isSecure || secure) && (cookie.expiresDate.map { $0 > now } ?? true)
        }
    }
}
