import WebKit

/// Serves tab-share frames over `lilo-capture://` as H.264, long-polled: parked until a newer frame (410 when the session ends).
/// Pulling keeps backpressure page-side and avoids base64 through evaluateJavaScript; `key=1` waits for a keyframe with its decoder config.
/// `frames/audio` serves a screen share's mono Float32 samples captured since the previous pull, the same way.
@MainActor
final class TabShareFrameSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lilo-capture"

    // https pages block subresources on non-secure schemes, so every frame fetch would fail, and a page's connect-src would block
    // (and report) them too. The registrations are global (once, on a throwaway pool); WKProcessPool is deprecated but the only
    // entry point, hence the lookup by name.
    private static let secureSchemeRegistration: Void = {
        guard let pool = (NSClassFromString("WKProcessPool") as? NSObject.Type)?.init() else { return }
        for name in ["_registerURLSchemeAsSecure:", "_registerURLSchemeAsBypassingContentSecurityPolicy:"] {
            let selector = NSSelectorFromString(name)
            if pool.responds(to: selector) { pool.perform(selector, with: scheme) }
        }
    }()

    override init() {
        super.init()
        _ = Self.secureSchemeRegistration
    }

    enum FrameResult {
        case frame(seq: Int, chunk: TabShareEncoder.Chunk)
        case samples(Data, rate: Double)
        case pending
        case gone
    }

    /// Resolves (token, afterSeq, wantsKey, pulling web view) against the live session. Set by `BrowserContext`.
    var frameProvider: ((String, Int, Bool, WKWebView) -> FrameResult)?
    /// Resolves (token, pulling web view) to the samples captured since the last pull. Set by `BrowserContext`.
    var audioProvider: ((String, WKWebView) -> FrameResult)?

    private struct Waiter {
        let task: any WKURLSchemeTask
        let webView: WKWebView
        let token: String
        let afterSeq: Int
        let wantsKey: Bool
        let isAudio: Bool
    }

    private var waiters: [ObjectIdentifier: Waiter] = [:]

    func hasWaiter(token: String) -> Bool { waiters.values.contains { $0.token == token } }

    /// Called by the session controller whenever a new frame lands or the session ends.
    func flushWaiters() {
        guard !waiters.isEmpty else { return }
        let flushed = waiters
        waiters.removeAll()
        for waiter in flushed.values {
            respond(to: waiter)
        }
    }

    // WebKit calls both on the main thread; handling synchronously keeps stop ordered after start,
    // so a stopped task is never answered (WKURLSchemeTask raises on that).
    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        nonisolated(unsafe) let urlSchemeTask = urlSchemeTask
        MainActor.assumeIsolated { start(urlSchemeTask, webView: webView) }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        nonisolated(unsafe) let urlSchemeTask = urlSchemeTask
        MainActor.assumeIsolated { _ = waiters.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) }
    }

    private func start(_ task: any WKURLSchemeTask, webView: WKWebView) {
        guard let url = task.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let token = queryItems.first(where: { $0.name == "token" })?.value else {
            respond(to: task, status: 400, body: Data(), headers: [:])
            return
        }
        let afterSeq = queryItems.first(where: { $0.name == "seq" })?.value.flatMap(Int.init) ?? 0
        let wantsKey = queryItems.contains { $0.name == "key" && $0.value == "1" }
        respond(to: Waiter(task: task, webView: webView, token: token, afterSeq: afterSeq, wantsKey: wantsKey, isAudio: components.path == "/audio"))
    }

    private func respond(to waiter: Waiter) {
        let result = waiter.isAudio
            ? audioProvider?(waiter.token, waiter.webView)
            : frameProvider?(waiter.token, waiter.afterSeq, waiter.wantsKey, waiter.webView)
        switch result ?? .gone {
        case .frame(let seq, let chunk):
            var headers = ["X-Lilo-Seq": "\(seq)", "X-Lilo-Key": chunk.config == nil ? "0" : "1"]
            if let config = chunk.config {
                headers["X-Lilo-Codec"] = config.codec
                headers["X-Lilo-Desc"] = config.description.base64EncodedString()
            }
            respond(to: waiter.task, status: 200, body: chunk.data, headers: headers)
        case .samples(let data, let rate):
            respond(to: waiter.task, status: 200, body: data, headers: ["X-Lilo-Rate": "\(rate)"])
        case .pending:
            waiters[ObjectIdentifier(waiter.task)] = waiter
        case .gone:
            respond(to: waiter.task, status: 410, body: Data(), headers: [:])
        }
    }

    private func respond(to task: any WKURLSchemeTask, status: Int, body: Data, headers: [String: String]) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging([
                  "Content-Type": "application/octet-stream",
                  "Content-Length": "\(body.count)",
                  "Cache-Control": "no-store",
                  "Access-Control-Allow-Origin": "*",
                  "Access-Control-Expose-Headers": "X-Lilo-Seq, X-Lilo-Key, X-Lilo-Codec, X-Lilo-Desc, X-Lilo-Rate"
              ]) { current, _ in current }) else { return }
        task.didReceive(response)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
    }
}
