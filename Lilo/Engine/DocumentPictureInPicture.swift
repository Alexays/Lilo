import AppKit
import WebKit

/// Document Picture-in-Picture, which WebKit does not implement: `requestWindow` asks Lilo to take the next
/// `window.open`, and the window controller hosts that popup in its dock or floating panel.
@MainActor
final class DocumentPiPBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let messageHandlerName = "liloDocumentPiP"

    /// Whether the tab of `webView` may open a PiP window of the requested size (zero for "any"); when it may,
    /// its next `window.open` must become that window.
    var onPrepare: ((WKWebView, NSSize) -> Bool)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame, let webView = message.webView, let body = message.body as? [String: Any],
              onPrepare?(webView, NSSize(width: body["width"] as? Double ?? 0, height: body["height"] as? Double ?? 0)) == true else {
            return (nil, "NotAllowedError: Picture-in-Picture is not available in this tab")
        }
        return (true, nil)
    }

    /// `window.documentPictureInPicture` for `PageWorld`, top-level documents only.
    static let pageModule = #"""
    function () {
      if (window.top !== window || 'documentPictureInPicture' in window) return;
      const open = window.open, round = Math.round, max = Math.max;
      let current = null, generation = 0;
      const domError = error => {
        const text = String(error && error.message || error), match = /^(\w+): (.*)$/.exec(text);
        return new DOMException(match ? match[2] : text, match ? match[1] : 'NotAllowedError');
      };
      class DocumentPictureInPicture extends EventTarget {
        get window() { return current; }
        requestWindow(options) {
          const width = max(0, round(Number(options && options.width) || 0)), height = max(0, round(Number(options && options.height) || 0));
          const request = ++generation;
          if (current) { const previous = current; current = null; try { previous.close(); } catch (e) {} }
          return lilo.post('liloDocumentPiP', { width, height }).then(() => {
            if (request !== generation) throw new DOMException('A newer request replaced this one.', 'AbortError');
            const win = apply(open, window, ['', '_blank', 'popup,width=' + (width || 400) + ',height=' + (height || 300)]);
            if (!win) throw new DOMException('The Picture-in-Picture window could not open.', 'NotAllowedError');
            current = win;
            apply(listen, win, ['pagehide', () => { if (current === win) current = null; }]);
            const event = new NativeEvent('enter');
            defineProperty(event, 'window', { value: win, enumerable: true });
            apply(dispatch, instance, [event]);
            return win;
          }, error => { throw domError(error); });
        }
      }
      const wire = lilo.eventHandlers(DocumentPictureInPicture.prototype, ['enter']);
      lilo.nativeClass(DocumentPictureInPicture);
      const instance = new DocumentPictureInPicture();
      wire(instance);
      lilo.accessors(window, { get documentPictureInPicture() { return instance; } });
    }
    """#

    /// Meet offers its Document PiP only to Chrome, and fixes the browser identity its WebRTC stack follows at
    /// load: Chrome is shown only in the microtask after a read of the API, so its PiP checks pass and its call
    /// stays on Safari's media path.
    static let meetModule = #"""
    function () {
      if (window.top !== window || location.hostname !== 'meet.google.com') return;
      const api = getOwnPropertyDescriptor(window, 'documentPictureInPicture');
      if (!api || !api.get) return;
      const microtask = queueMicrotask;
      let armed = false, safari;
      safari = lilo.accessors(Navigator.prototype, { get userAgent() {
        return armed ? '\#(ChromeMasquerade.chromeUserAgent)' : apply(safari, this, []);
      } }).userAgent;
      lilo.accessors(window, { get documentPictureInPicture() {
        if (!armed) { armed = true; microtask(() => { armed = false; }); }
        return apply(api.get, this, []);
      } });
    }
    """#
}
