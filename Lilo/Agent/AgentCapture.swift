import Foundation
import WebKit

/// Console and network capture for one agent tab, installed only while an agent drives it.
@MainActor
final class AgentCapture: NSObject {
    struct Request {
        let id: Int
        var method: String
        var url: String
        var status: Int?
        var mimeType: String?
        /// The Content-Length header: the delegate never sees the body.
        var size: Int64?
        var failed = false
        let startedAt: Date
        var duration: TimeInterval?
    }

    static let maxEntries = 1000
    static let consoleHook = """
        (() => {
          if (window.__liloConsole) return
          const log = window.__liloConsole = []
          const push = (level, args) => {
            const text = args.map(a => {
              if (typeof a === 'string') return a
              if (a === null || typeof a !== 'object') return String(a)
              // The page's getters may throw: the page's own console call must not.
              try {
                // An Error of another frame fails instanceof: whatever carries a message reads as one. WebKit's
                // stack holds the frames only, never the message.
                if (a instanceof Error || typeof a.message === 'string') {
                  return `${a.name || 'Error'}: ${a.message}` + (typeof a.stack === 'string' && a.stack ? '\\n' + a.stack : '')
                }
                // Stops descending once the text is long enough: a huge object costs only what is kept of it.
                let used = 0
                const json = JSON.stringify(a, (key, value) => {
                  if (used > 5000) return undefined
                  used += key.length + (typeof value === 'string' ? value.length : 4)
                  return Array.isArray(value) && value.length > 5000 ? value.slice(0, 5000) : value
                })
                // An object with no data of its own (a class instance) stringifies to "{}": its class says more.
                return json && json !== '{}' ? json : `[object ${a.constructor?.name || 'Object'}]`
              } catch { return Object.prototype.toString.call(a) }
            }).join(' ')
            log.push({ level, text: text.slice(0, 5000), time: Date.now(), url: location.href })
            if (log.length > \(maxEntries)) log.shift()
          }
          const wrapped = ['log', 'info', 'warn', 'error', 'debug'].map(level => {
            const original = console[level]
            const wrapper = console[level] = function (...args) { push(level, args); return original.apply(this, args) }
            return { level, original, wrapper }
          })
          const onError = e => push('error', [e.error ?? e.message])
          const onRejection = e => push('error', ['Unhandled rejection:', e.reason])
          addEventListener('error', onError)
          addEventListener('unhandledrejection', onRejection)
          log.restore = () => {
            for (const { level, original, wrapper } of wrapped) if (console[level] === wrapper) console[level] = original
            removeEventListener('error', onError)
            removeEventListener('unhandledrejection', onRejection)
            delete window.__liloConsole
          }
        })()
        """

    private(set) var requests: [Request] = []
    /// What Lilo answered for the agent (a dialog, a permission, a sign-in). Kept here, not in the page:
    /// one raised during a navigation would go with the document it was written to.
    private var notes: [[String: Any]] = []
    private(set) var usesResourceLoadDelegate = false
    /// The loads in flight: each one's index in `requests`, removed as it completes.
    private(set) var indexByLoad: [UInt64: Int] = [:]
    /// When a request last started or ended, for a page that only goes quiet once its network does.
    private(set) var lastNetworkActivity = ContinuousClock.now
    private var nextRequestId = 1
    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    private static let setDelegate = NSSelectorFromString("_setResourceLoadDelegate:")
    private static let resourceLoadID = NSSelectorFromString("resourceLoadID")

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        if webView.responds(to: Self.setDelegate) {
            webView.perform(Self.setDelegate, with: self)
            usesResourceLoadDelegate = true
        }
        // The URL changes as a navigation starts, often still in the old document: the end of the load
        // hooks the new one, in case the start was too early.
        let hook: @Sendable (WKWebView) -> Void = { webView in MainActor.assumeIsolated { WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(Self.consoleHook) } }
        observations = [
            webView.observe(\.url, options: [.initial]) { webView, _ in hook(webView) },
            webView.observe(\.isLoading, options: [.new]) { webView, change in if change.newValue == false { hook(webView) } }
        ]
    }

    func stop() {
        observations.forEach { $0.invalidate() }
        observations = []
        if usesResourceLoadDelegate { webView?.perform(Self.setDelegate, with: nil) }
        webView?.evaluateJavaScript("window.__liloConsole?.restore()")
    }

    /// Console entries of the current document, oldest first.
    func consoleMessages() async -> [[String: Any]] {
        guard let webView else { return [] }
        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(Self.consoleHook)
        let page = (try? await webView.evaluateJavaScript("window.__liloConsole ?? []") as? [[String: Any]]) ?? []
        let time = { (entry: [String: Any]) in (entry["time"] as? NSNumber)?.doubleValue ?? 0 }
        return (page + notes).sorted { time($0) < time($1) }
    }

    /// Without the private delegate: what resource timing knows, which has no status codes.
    func timedRequests() async -> [[String: Any]] {
        guard let webView else { return [] }
        let script = """
            performance.getEntriesByType('resource').concat(performance.getEntriesByType('navigation'))
              .map(e => ({ url: e.name, type: e.initiatorType || 'navigation', duration: Math.round(e.duration), status: e.responseStatus || null }))
            """
        return (try? await webView.evaluateJavaScript(script) as? [[String: Any]]) ?? []
    }

    func note(_ text: String) {
        notes.append(["level": "info", "text": text, "time": Date().timeIntervalSince1970 * 1000, "url": webView?.url?.absoluteString ?? ""])
        if notes.count > 100 { notes.removeFirst() }
    }

    private func loadId(_ resourceLoad: AnyObject) -> UInt64? {
        guard resourceLoad.responds(to: Self.resourceLoadID) else { return nil }
        return (resourceLoad.value(forKey: "resourceLoadID") as? NSNumber)?.uint64Value
    }

    @objc(webView:resourceLoad:didSendRequest:)
    func resourceLoad(_ webView: WKWebView, resourceLoad: AnyObject, didSendRequest request: URLRequest) {
        guard let id = loadId(resourceLoad) else { return }
        lastNetworkActivity = .now
        indexByLoad[id] = requests.count
        requests.append(Request(id: nextRequestId, method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "", startedAt: Date()))
        nextRequestId += 1
        // The oldest go a hundred at a time, so the indexes in flight move once per hundred requests, not on each.
        if requests.count >= Self.maxEntries + 100 {
            requests.removeFirst(100)
            indexByLoad = indexByLoad.compactMapValues { $0 >= 100 ? $0 - 100 : nil }
        }
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func resourceLoad(_ webView: WKWebView, resourceLoad: AnyObject, didReceiveResponse response: URLResponse) {
        guard let id = loadId(resourceLoad), let index = indexByLoad[id] else { return }
        requests[index].status = (response as? HTTPURLResponse)?.statusCode
        requests[index].mimeType = response.mimeType
        if response.expectedContentLength >= 0 { requests[index].size = response.expectedContentLength }
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func resourceLoad(_ webView: WKWebView, resourceLoad: AnyObject, didCompleteWithError error: Error?, response: URLResponse?) {
        guard let id = loadId(resourceLoad), let index = indexByLoad.removeValue(forKey: id) else { return }
        lastNetworkActivity = .now
        if let status = (response as? HTTPURLResponse)?.statusCode { requests[index].status = status }
        requests[index].failed = error != nil
        requests[index].duration = Date().timeIntervalSince(requests[index].startedAt)
    }
}
