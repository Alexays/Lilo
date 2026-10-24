import WebKit

/// Serves `view-source:<url>`: renders the raw markup the tab already loaded when it was handed over,
/// else re-fetches the page with the tab's cookies.
@MainActor
final class ViewSourceSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "view-source"

    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The markup of the page whose source is about to open, used once.
    private var handedOver: (url: URL, data: Data)?

    func handOver(_ data: Data, of url: URL) {
        handedOver = (url, data)
    }

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        nonisolated(unsafe) let urlSchemeTask = urlSchemeTask
        MainActor.assumeIsolated { start(urlSchemeTask, in: webView) }
    }

    // Stop arrives on the main thread before any later answer, so cancelling here guarantees a
    // stopped task is never answered (WKURLSchemeTask raises on that).
    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        nonisolated(unsafe) let urlSchemeTask = urlSchemeTask
        MainActor.assumeIsolated { running.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
    }

    private func start(_ task: any WKURLSchemeTask, in webView: WKWebView) {
        let key = ObjectIdentifier(task)
        // Top-level documents only: the fetch carries the user's cookies, so a page must not be able
        // to frame or fetch it.
        guard let url = task.request.url, task.request.mainDocumentURL == url,
              let target = URL(string: String(url.absoluteString.dropFirst(Self.scheme.count + 1))),
              target.scheme == "http" || target.scheme == "https" else {
            respond(to: task, url: task.request.url, html: Self.page(title: "view-source", body: "Unsupported URL"))
            return
        }
        if let handedOver, handedOver.url == target {
            self.handedOver = nil
            respond(to: task, url: url, html: Self.page(title: url.absoluteString, body: Self.decode(handedOver.data, encodingName: nil)))
            return
        }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let userAgent = webView.customUserAgent
        running[key] = Task { [weak self] in
            let html: String
            do {
                html = try await Self.page(title: url.absoluteString, body: Self.fetchSource(target, cookieStore: cookieStore, userAgent: userAgent))
            } catch {
                html = Self.page(title: url.absoluteString, body: error.localizedDescription)
            }
            guard let self, running.removeValue(forKey: key) != nil else { return }
            respond(to: task, url: url, html: html)
        }
    }

    private func respond(to task: any WKURLSchemeTask, url: URL?, html: String) {
        let data = Data(html.utf8)
        let response = URLResponse(url: url ?? URL(string: "\(Self.scheme):")!, mimeType: "text/html",
                                   expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func fetchSource(_ url: URL, cookieStore: WKHTTPCookieStore, userAgent: String?) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        let jar = HTTPCookieStorage()
        // The jar filters by domain, path and secure flag the way the page's own request did.
        for cookie in await cookieStore.allCookies() { jar.setCookie(cookie) }
        config.httpCookieStorage = jar
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await session.data(for: request)
        return decode(data, encodingName: (response as? HTTPURLResponse)?.textEncodingName)
    }

    private nonisolated static func decode(_ data: Data, encodingName: String?) -> String {
        let encoding = encodingName
            .map { CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)) }
        if let encoding, encoding != UInt(kCFStringEncodingInvalidId), let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
            return text
        }
        // Latin-1 maps every byte, so a page that is not valid UTF-8 still shows.
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    nonisolated static func page(title: String, body: String) -> String {
        var lines = ""
        lines.reserveCapacity(body.utf8.count + body.utf8.count / 4)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += "<span>"
            lines += escape(line.hasSuffix("\r") ? line.dropLast() : line)
            lines += "</span>\n"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(Substring(title)))</title>
        <meta name="color-scheme" content="light dark"><style>
        body{margin:0;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
        pre{margin:0;padding:8px 0;white-space:pre-wrap;word-break:break-all;counter-reset:l}
        span{display:block;padding-left:5.5em;text-indent:-4.5em}
        span::before{counter-increment:l;content:counter(l);display:inline-block;width:3.5em;margin-right:1em;text-align:right;color:GrayText;user-select:none}
        </style></head><body><pre>\(lines)</pre></body></html>
        """
    }

    nonisolated private static func escape(_ text: Substring) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(char)
            }
        }
        return out
    }
}
