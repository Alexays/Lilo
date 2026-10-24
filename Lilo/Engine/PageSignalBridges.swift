import WebKit

@MainActor
final class FormDirtyBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "liloFormDirty"
    var onChange: ((WKWebView, Bool) -> Void)?

    static let polyfillSource = """
    (function () {
      'use strict';
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liloFormDirty;
      if (!h) return;
      var dirty = false;
      function report(v) { if (v !== dirty) { dirty = v; try { h.postMessage({ dirty: v }); } catch (e) {} } }
      document.addEventListener('input', function () { report(true); }, true);
      document.addEventListener('reset', function () { report(false); }, true);
      document.addEventListener('submit', function () { report(false); }, true);
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let dirty = body["dirty"] as? Bool else { return }
        guard let webView = message.webView else { return }
        onChange?(webView, dirty)
    }
}
