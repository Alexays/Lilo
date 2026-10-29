import WebKit

@MainActor
final class FormDirtyBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "liloFormDirty"
    var onChange: ((WKWebView, Bool) -> Void)?

    /// Runs in `PageWorld.bridgeWorld`: it only listens to the page's DOM events.
    static let scriptSource = """
    (function () {
      'use strict';
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liloFormDirty;
      if (!h) return;
      var dirty = false;
      function report(v) { if (v !== dirty) { dirty = v; try { h.postMessage({ dirty: v }); } catch (e) {} } }
      document.addEventListener('input', function () { report(true); }, true);
      // A subframe's form ending must not clear a main-frame form still being edited.
      if (window !== window.top) return;
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
            hasLiveConnection: body["rtc"] as? Bool == true
        ))
    }
}
