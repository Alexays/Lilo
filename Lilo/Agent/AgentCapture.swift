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
    /// The `PageWorld` module of the console capture, which patches the console only once an agent drives the tab.
    static let consoleModule = #"""
    function () {
      if (window.top !== window) return;
      const unlisten = EventTarget.prototype.removeEventListener, objectToString = Object.prototype.toString;
      const { getPrototypeOf } = Reflect, { isArray } = Array;
      const { get: domName } = getOwnPropertyDescriptor(DOMException.prototype, 'name');
      const { get: domMessage } = getOwnPropertyDescriptor(DOMException.prototype, 'message');
      let log, stop;
      // Reads data properties only, up the prototype chain: a getter is the page's code, which logging must not run.
      // A DOMException's native name and message getters, captured before the page runs, are the exception.
      const data = (object, key) => {
        for (let o = object; o; o = getPrototypeOf(o)) {
          const d = getOwnPropertyDescriptor(o, key);
          if (d) return 'value' in d ? d.value : d.get === domName || d.get === domMessage ? apply(d.get, object, []) : undefined;
        }
      };
      // JSON of the own enumerable data, an accessor showing as "[Getter]", without a toJSON or a getter of the page.
      // Stops descending once the text is long enough: a huge object costs only what is kept of it.
      let used, parents;
      const json = value => {
        if (value === null || typeof value !== 'object') {
          const text = typeof value === 'bigint' ? String(value) : stringify(value) ?? 'null';
          used += text.length;
          return text;
        }
        for (let i = 0; i < parents.length; i++) if (parents[i] === value) return '"[Circular]"';
        parents[parents.length] = value;
        const array = isArray(value), keys = array ? undefined : ownKeys(value);
        let text = array ? '[' : '{', comma = '';
        for (let i = 0, n = array ? value.length : keys.length; i < n && used < 5000; i++) {
          const key = array ? i : keys[i], d = getOwnPropertyDescriptor(value, key);
          if (!array && (typeof key !== 'string' || !d.enumerable)) continue;
          const v = d && ('value' in d ? d.value : '[Getter]');
          if (!array && (v === undefined || typeof v === 'function' || typeof v === 'symbol')) continue;
          used += array ? 1 : key.length + 4;
          text += comma + (array ? '' : stringify(key) + ':') + json(v);
          comma = ',';
        }
        parents.length--;
        return text + (array ? ']' : '}');
      };
      lilo.on('console', action => {
        if (action === 'stop') return void (stop && stop());
        if (!log) {
          log = [];
          const push = (level, args) => {
            const text = args.map(a => {
              if (typeof a === 'string') return a;
              if (a === null || typeof a !== 'object') return String(a);
              // A proxy's traps or a deep nesting may throw: the page's own console call must not.
              try {
                // An Error of another frame fails instanceof: whatever carries a message reads as one. WebKit's
                // stack holds the frames only, never the message.
                const message = data(a, 'message');
                if (a instanceof NativeError || typeof message === 'string') {
                  const name = data(a, 'name'), stack = data(a, 'stack');
                  return `${typeof name === 'string' && name ? name : 'Error'}: ${typeof message === 'string' ? message : ''}`
                    + (typeof stack === 'string' && stack ? '\n' + stack : '');
                }
                used = 0;
                parents = [];
                const text = json(a);
                // An object with no data of its own (a class instance) prints as "{}": its class says more.
                if (text !== '{}') return text;
                const name = data(data(a, 'constructor'), 'name');
                return `[object ${typeof name === 'string' && name ? name : 'Object'}]`;
              } catch (e) { return apply(objectToString, a, []); }
            }).join(' ');
            log.push({ level, text: text.slice(0, 5000), time: Date.now(), url: location.href });
            if (log.length > \#(maxEntries)) log.shift();
          };
          const wrappers = create(null);
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            wrappers[level] = { [level](...args) { push(level, args); return apply(originals[level], this, args); } }[level];
          }
          const originals = lilo.methods(console, wrappers);
          const onError = e => push('error', [e.error ?? e.message]);
          const onRejection = e => push('error', ['Unhandled rejection:', e.reason]);
          apply(listen, window, ['error', onError]);
          apply(listen, window, ['unhandledrejection', onRejection]);
          stop = () => {
            for (const level in wrappers) if (console[level] === wrappers[level]) console[level] = originals[level];
            apply(unlisten, window, ['error', onError]);
            apply(unlisten, window, ['unhandledrejection', onRejection]);
            log = stop = undefined;
          };
        }
        if (action === 'read') return log;
      });
    }
    """#
    static let startConsole = PageWorld.push("console", ["start"])

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
    private(set) weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    private static let setDelegate = NSSelectorFromString("_setResourceLoadDelegate:")
    private static let resourceLoadID = NSSelectorFromString("resourceLoadID")

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        if webView.responds(to: Self.setDelegate) {
            unsafe webView.perform(Self.setDelegate, with: self)
            usesResourceLoadDelegate = true
        }
        // The URL changes as a navigation starts, often still in the old document: the end of the load
        // hooks the new one, in case the start was too early.
        let hook: @Sendable (WKWebView) -> Void = { webView in
            MainActor.assumeIsolated { WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(Self.startConsole, in: nil, in: PageWorld.bridgeWorld) }
        }
        observations = [
            webView.observe(\.url, options: [.initial]) { webView, _ in hook(webView) },
            webView.observe(\.isLoading, options: [.new]) { webView, change in if change.newValue == false { hook(webView) } }
        ]
    }

    func stop() {
        observations.forEach { $0.invalidate() }
        observations = []
        if usesResourceLoadDelegate { unsafe webView?.perform(Self.setDelegate, with: nil) }
        if let webView { WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("console", ["stop"]), in: nil, in: PageWorld.bridgeWorld) }
    }

    /// Console entries of the current document, oldest first.
    func consoleMessages() async -> [[String: Any]] {
        guard let webView else { return [] }
        let page = await withCheckedContinuation { continuation in
            WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("console", ["read"]), in: nil, in: PageWorld.bridgeWorld) {
                nonisolated(unsafe) let entries = $0 as? [[String: Any]] ?? []
                unsafe continuation.resume(returning: entries)
            }
        }
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
