import Foundation
import WebKit

/// An extension's `fetch` with `credentials: "include"` to a host it may access, sent with every cookie of the
/// profile for that URL as Chrome sends them. WebKit treats an extension origin as another site, so it leaves out
/// `SameSite=Lax` and `Strict` cookies (WEBKIT-GAPS.md, gap 81): signed-in sessions (ChatGPT's) read as signed out.
/// Answers nil for a request WebKit sends as Chrome does, which the page then sends itself. The call answers with the
/// response's head; its body follows as `fetch.onBody` events to the calling context, one per network read.
@MainActor
final class CredentialedFetchBridgeHandler: NSObject, GapHandler, URLSessionDataDelegate {
    let gapActions: Set<String> = ["fetch.credentialed", "fetch.read", "fetch.cancel"]

    /// A response's head, and what lets its body come or stops it there.
    private typealias Head = (response: HTTPURLResponse, proceed: @Sendable (URLSession.ResponseDisposition) -> Void)

    private struct Request {
        let id: String
        let extensionId: String
        weak var registry: ProfileExtensionRegistry?
        /// The context reading the response: nil for the worker, else its page's channel.
        let channel: Int?
        /// The hop under way; nil while the next one's cookies are read.
        var task: URLSessionDataTask?
        var head: CheckedContinuation<Head?, Never>?
        /// Body bytes sent that the context has not reported read.
        var unread = 0
    }

    /// Unread body bytes past which a request pauses: a reader that stalls holds the network, not memory. credentialed-fetch.ts
    /// reports what it read every half of it.
    private nonisolated static let window = 1 << 20

    /// Each request under way by its extension and request id, which an abort cancels, as Chrome stops the request.
    private var running: [String: Request] = [:]

    /// Each profile's session, through its proxy as the profile's pages are; rebuilt when that proxy changes.
    private var sessions: [UUID: URLSession] = [:]
    nonisolated(unsafe) private var observers: [Any] = []

    override init() {
        super.init()
        unsafe observers.append(NotificationCenter.default.addObserver(forName: .extensionProxyDidChange, object: nil, queue: .main) { [weak self] note in
            guard let registry = note.object as? ProfileExtensionRegistry else { return }
            MainActor.assumeIsolated { self?.sessions.removeValue(forKey: registry.profileId)?.finishTasksAndInvalidate() }
        })
        // A request outlives neither the page or worker reading it nor its extension. A worker's notification names no channel.
        for name in [Notification.Name.extensionPageChannelDidClose, .extensionWorkerDidStop, .extensionDidUnload] {
            unsafe observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let extensionId = note.userInfo?["extensionId"] as? String else { return }
                let channel = note.userInfo?["channel"] as? Int
                let events = note.object as? GapEvents
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (key, request) in self.running where request.extensionId == extensionId
                        && (name == .extensionDidUnload || request.channel == channel && request.registry?.gapEvents === events) {
                        self.stop(key)
                    }
                }
            })
        }
    }

    deinit {
        unsafe observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func session(for registry: ProfileExtensionRegistry) -> URLSession {
        if let session = sessions[registry.profileId] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.proxyConfigurations = registry.controller.configuration.defaultWebsiteDataStore?.proxyConfigurations ?? []
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        sessions[registry.profileId] = session
        return session
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let id = call.string("requestId") else { return nil }
        let key = "\(call.extensionId)\u{1f}\(id)"
        switch call.action {
        case "fetch.cancel":
            stop(key)
        case "fetch.read":
            running[key]?.unread -= call.int("bytes") ?? 0
            if let request = running[key], request.unread < Self.window, request.task?.state == .suspended { request.task?.resume() }
        default:
            return await send(call, id: id, key: key)
        }
        return nil
    }

    private func stop(_ key: String) {
        guard let request = running.removeValue(forKey: key) else { return }
        request.task?.cancel()
        request.head?.resume(returning: nil)
    }

    private func send(_ call: GapCall, id: String, key: String) async -> Any? {
        guard let context = call.context,
              var url = call.string("url").flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              context.hasAccess(to: url) else { return nil }
        running[key] = Request(id: id, extensionId: call.extensionId, registry: call.registry, channel: call.int("pageChannel"))
        let store = WKEngineFactory.persistentDataStore(for: call.registry.profileId).httpCookieStore
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
            // Aborted while its cookies were read.
            guard running[key] != nil else { return BridgeError("Failed to fetch") }
            let task = session(for: call.registry).dataTask(with: request)
            task.taskDescription = key
            running[key]?.task = task
            guard let (response, proceed) = await withCheckedContinuation({ (head: CheckedContinuation<Head?, Never>) in
                running[key]?.head = head
                task.resume()
            }) else { return BridgeError("Failed to fetch") }
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
                proceed(.cancel)
                // The hop's end is not the request's.
                running[key]?.task = nil
                if call.string("redirect") == "error" || hop == 20 {
                    running[key] = nil
                    return BridgeError("Failed to fetch")
                }
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
            // Aborted, or its connection lost, while its cookies were stored.
            guard running[key] != nil else { return BridgeError("Failed to fetch") }
            proceed(.allow)
            return [
                "status": response.statusCode,
                "headers": fields.filter { $0.key.lowercased() != "set-cookie" }.map { [$0.key, $0.value] },
                "url": url.absoluteString,
                "redirected": hop > 0
            ] as [String: Any]
        }
        return BridgeError("Failed to fetch")
    }

    // MARK: - URLSessionDataDelegate

    /// The body waits until `send` has stored the head's cookies and knows the hop is the last.
    nonisolated func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let key = dataTask.taskDescription, let request = running[key], request.task === dataTask,
                  let head = request.head, let response = response as? HTTPURLResponse else { return completionHandler(.cancel) }
            running[key]?.head = nil
            head.resume(returning: (response, completionHandler))
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard let key = dataTask.taskDescription, let request = running[key], request.task === dataTask else { return }
            running[key]?.unread += data.count
            if request.unread + data.count >= Self.window { dataTask.suspend() }
            request.registry?.gapEvents.emit(
                "fetch", "onBody", args: [["requestId": request.id, "chunk": data.base64EncodedString()]],
                to: request.extensionId, contexts: [request.channel], wakes: false
            )
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let key = task.taskDescription, let request = running[key], request.task === task else { return }
            running[key] = nil
            // Before its head, the call itself fails.
            if let head = request.head { return head.resume(returning: nil) }
            request.registry?.gapEvents.emit(
                "fetch", "onBody", args: [["requestId": request.id, "failed": error != nil]],
                to: request.extensionId, contexts: [request.channel], wakes: false
            )
        }
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
            // RFC 6265's path-match: `/foo` covers `/foo` and `/foo/x`, not `/foobar`.
            let pathMatches = path == cookie.path || path.hasPrefix(cookie.path)
                && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/"))
            return domainMatches && pathMatches && (!cookie.isSecure || secure) && (cookie.expiresDate.map { $0 > now } ?? true)
        }
    }
}
