import WebKit

@MainActor
final class FormDirtyBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "liloFormDirty"
    /// (webView, isDirty, isMainFrame)
    var onChange: ((WKWebView, Bool, Bool) -> Void)?

    /// Runs in `PageWorld.bridgeWorld`: it only listens to the page's DOM events. A subframe only ever reports dirty: the main frame alone
    /// rechecks, when the page goes hidden, whether an edited field still holds text, so a sent message or a cleared draft frees the tab.
    static let scriptSource = """
    (function () {
      'use strict';
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liloFormDirty;
      if (!h) return;
      var dirty = false;
      function report(v) { if (v !== dirty) { dirty = v; try { h.postMessage({ dirty: v }); } catch (e) {} } }
      var nonText = /^(?:button|checkbox|color|file|hidden|image|radio|range|reset|submit)$/;
      var isTop = window === window.top;
      // Weak, so a removed composer is not kept alive; the baseline is defaultValue before the page sees the input, which React
      // only syncs to the value afterwards.
      var edited = [], seen = new WeakSet(), untracked = false;
      document.addEventListener('input', function (event) {
        var t = event.composedPath()[0];
        if (t instanceof HTMLSelectElement || (t instanceof HTMLInputElement && nonText.test(t.type))) return;
        report(true);
        if (!isTop || seen.has(t)) return;
        if (t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement) edited.push({ ref: new WeakRef(t), base: t.defaultValue });
        else if (t instanceof HTMLElement && t.isContentEditable) edited.push({ ref: new WeakRef(t), base: null });
        else { untracked = true; return; }
        seen.add(t);
      }, true);
      if (!isTop) return;
      function clear() { edited = []; seen = new WeakSet(); untracked = false; report(false); }
      document.addEventListener('reset', clear, true);
      document.addEventListener('submit', clear, true);
      document.addEventListener('visibilitychange', function () {
        if (!dirty || !document.hidden) return;
        // A detached field stays listed: `seen` skips it if it is attached and edited again.
        edited = edited.filter(function (c) { return c.ref.deref(); });
        report(untracked || edited.some(function (c) {
          var t = c.ref.deref();
          if (!t.isConnected) return false;
          return c.base === null ? t.textContent.trim() !== '' : t.value !== '' && t.value !== c.base;
        }));
      }, true);
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let dirty = body["dirty"] as? Bool else { return }
        guard let webView = message.webView else { return }
        onChange?(webView, dirty, message.frameInfo.isMainFrame)
    }
}

/// Call and track controls `WKWebViewTab.mediaControlModule` reports from a page's Media Session.
@MainActor
final class CallControlsBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "liloCall"
    var onChange: ((WKWebView, WKWebViewTab.CallControls) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let webView = message.webView else { return }
        onChange?(webView, WKWebViewTab.CallControls(
            microphoneActive: body["microphone"] as? Bool,
            cameraActive: body["camera"] as? Bool,
            actions: Set(WKWebViewTab.callActions.filter { body[$0] as? Bool == true }),
            hasTrackControls: body["tracks"] as? Bool == true,
            hasPictureInPictureAction: body["pip"] as? Bool == true,
            hasLiveConnection: body["rtc"] as? Bool == true,
            hasPeerConnection: body["peer"] as? Bool == true
        ))
    }
}
