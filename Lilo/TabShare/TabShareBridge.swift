import WebKit

/// Outcome of the chrome tab-share picker.
enum TabSharePickerChoice {
    case tab(UUID)
    case system
    case cancel
}

/// Bridges the page-facing tab-share `getDisplayMedia`: WebKit only captures screens and windows, so a tab pick builds the stream
/// page-side from a canvas fed by `TabShareSessionController`; a screen or window pick runs WebKit's own picker.
@MainActor
final class TabShareBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let messageHandlerName = "liloTabShare"

    /// Presents the chrome tab picker; nil (headless) falls back to the system picker.
    var pickerPresenter: ((_ originHost: String, _ requester: WKWebView) async -> TabSharePickerChoice)?
    /// Starts a frame-ferry session for the picked tab. Returns the shim reply payload
    /// (mode/token/width/height) or nil when the tab has no live engine.
    var sessionStarter: ((_ tabId: UUID, _ requester: WKWebView) -> [String: Any]?)?
    var sessionStopper: ((_ token: String) -> Void)?
    /// Redeems a `chrome.tabCapture` / `chrome.desktopCapture` stream id for the calling frame's
    /// origin (`chromeMediaSource` 'tab' or 'desktop'). Returns the shim reply payload, nil when
    /// the id is unknown, used, expired or meant for another origin.
    var streamOpener: ((_ streamId: String, _ mediaSource: String, _ origin: String, _ requester: WKWebView) async -> [String: Any]?)?
    private var pickingWebViews: Set<ObjectIdentifier> = []

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else {
            return (nil, "invalid request")
        }
        switch action {
        case "pick":
            guard let requester = message.webView else { return (nil, "no web view") }
            // The message handler is reachable from any frame: mirror the shim's same-origin rule here,
            // and keep a single picker per web view.
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame
                    || (origin.protocol == requester.url?.scheme && origin.host == requester.url?.host
                        && origin.port == (requester.url?.port ?? 0)) else {
                return (nil, "cross-origin frame")
            }
            let requesterId = ObjectIdentifier(requester)
            guard pickingWebViews.insert(requesterId).inserted else { return (nil, "picker already open") }
            defer { pickingWebViews.remove(requesterId) }
            let reply = await pick(originHost: origin.host, requester: requester)
            if reply["mode"] as? String == "system", let id = body["id"] as? String {
                // The page's user activation was spent on the async picker; app-injected JS carries
                // a fresh one, and native getDisplayMedia also rejects a document without focus.
                requester.window?.makeFirstResponder(requester)
                _ = try? await requester.callAsyncJavaScript(
                    "window.__liloNativeDisplay(id)", arguments: ["id": id], in: message.frameInfo, contentWorld: .page
                )
            }
            return (reply, nil)
        case "open":
            guard let requester = message.webView, let streamId = body["streamId"] as? String,
                  let mediaSource = body["source"] as? String else { return (nil, "invalid request") }
            let origin = message.frameInfo.securityOrigin
            let originString = origin.port == 0 ? "\(origin.protocol)://\(origin.host)" : "\(origin.protocol)://\(origin.host):\(origin.port)"
            guard let reply = await streamOpener?(streamId, mediaSource, originString, requester) else { return (nil, "invalid stream id") }
            return (reply, nil)
        case "stop":
            if let token = body["token"] as? String { sessionStopper?(token) }
            return (true, nil)
        default:
            return (nil, "unknown action")
        }
    }

    func pick(originHost: String, requester: WKWebView) async -> [String: Any] {
        guard let pickerPresenter else { return ["mode": "system"] }
        switch await pickerPresenter(originHost, requester) {
        case .system:
            return ["mode": "system"]
        case .cancel:
            return ["mode": "cancel"]
        case .tab(let tabId):
            guard let payload = sessionStarter?(tabId, requester) else { return ["mode": "cancel"] }
            return payload
        }
    }
}

// MARK: - Shim source

extension TabShareBridge {
    /// JS shim injected at document start (page world). Overrides `getDisplayMedia` to offer tab
    /// sharing; the native path stays reachable through the saved original. `getUserMedia` with
    /// Chrome's `chromeMediaSource` redeems an extension's capture stream id on the same ferry.
    static let shimSource: String = """
(function(){
'use strict';
var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liloTabShare;
if (!handler || !navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) return;
// Cross-origin frames keep the native call, which enforces their display-capture permissions policy.
try { if (window.top !== window && window.top.location.origin !== location.origin) return; } catch (e) { return; }
var native = navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
var Decoder = window.VideoDecoder, Chunk = window.EncodedVideoChunk;
// Captured before any page script runs, so the page cannot fake a user gesture.
var activation = navigator.userActivation;
var activationDesc = activation && Object.getOwnPropertyDescriptor(Object.getPrototypeOf(activation), 'isActive');
var isActiveGetter = activationDesc && activationDesc.get;
var active = {};
var nativePending = {};
// Non-writable: native calls it with a user gesture, which page code must not be able to borrow.
Object.defineProperty(window, '__liloNativeDisplay', { value: function(id){
  var p = nativePending[id];
  if (p && !p.promise) p.promise = native(p.constraints);
} });
// Static content paints nothing, so the canvas track would emit no frames: the encoder could
// neither refine a blurry first frame nor answer a keyframe request. Repaint at this interval.
var refreshMs = 200;
function endSession(token, notifyNative){
  var s = active[token];
  if (!s) return;
  delete active[token];
  clearInterval(s.refresh);
  if (s.decoder && s.decoder.state !== 'closed') s.decoder.close();
  if (s.last) s.last.close();
  if (notifyNative) { try { handler.postMessage({ action: 'stop', token: token }); } catch (e) {} }
  s.stream.getTracks().forEach(function(t){
    s.nativeStops.get(t)();
    if (!notifyNative) { try { t.dispatchEvent(new Event('ended')); } catch (e) {} }
  });
}
window.__liloTabShareEnded = function(token){ endSession(token, false); };
window.addEventListener('pagehide', function(){
  Object.keys(active).forEach(function(token){ endSession(token, true); });
});
// Frames arrive as H.264 in sequence; a decoder starts (or restarts after an error) on a keyframe,
// whose headers carry its config.
function configure(entry, codec, desc){
  if (entry.decoder && entry.decoder.state !== 'closed') entry.decoder.close();
  entry.decoder = new Decoder({
    output: function(frame){
      entry.ctx.drawImage(frame, 0, 0, entry.canvas.width, entry.canvas.height);
      if (entry.last) entry.last.close();
      entry.last = frame;
      entry.drawnAt = performance.now();
    },
    error: function(){ entry.decoder = null; entry.needKey = true; }
  });
  entry.decoder.configure({
    codec: codec,
    description: Uint8Array.from(atob(desc), function(c){ return c.charCodeAt(0); }),
    hardwareAcceleration: 'prefer-hardware',
    optimizeForLatency: true
  });
  entry.desc = desc;
}
function pump(s){
  var e = active[s.token];
  if (!e) return;
  fetch(s.frameURL + '&seq=' + s.seq + (e.needKey ? '&key=1' : ''), { cache: 'no-store' }).then(function(r){
    if (!active[s.token]) return;
    if (r.status === 410) { endSession(s.token, false); return; }
    if (r.status !== 200) { setTimeout(function(){ pump(s); }, 250); return; }
    var seq = parseInt(r.headers.get('X-Lilo-Seq') || '0', 10);
    var key = r.headers.get('X-Lilo-Key') === '1';
    var codec = r.headers.get('X-Lilo-Codec');
    var desc = r.headers.get('X-Lilo-Desc');
    return r.arrayBuffer().then(function(data){
      var entry = active[s.token];
      if (!entry) return;
      if (key && (!entry.decoder || entry.desc !== desc)) configure(entry, codec, desc);
      if (entry.decoder && (key || !entry.needKey)) {
        entry.decoder.decode(new Chunk({ type: key ? 'key' : 'delta', timestamp: seq * 33333, data: data }));
        entry.needKey = false;
      }
      s.seq = seq;
      pump(s);
    });
  }).catch(function(){
    if (active[s.token]) setTimeout(function(){ pump(s); }, 250);
  });
}
function ferryStream(res){
  var canvas = document.createElement('canvas');
  canvas.width = res.width;
  canvas.height = res.height;
  var ctx = canvas.getContext('2d');
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, res.width, res.height);
  var stream = canvas.captureStream(30);
  var nativeStops = new Map();
  stream.getTracks().forEach(function(t){
    t.contentHint = 'detail';
    nativeStops.set(t, t.stop.bind(t));
    t.stop = function(){ endSession(res.token, true); };
    var nativeSettings = t.getSettings.bind(t);
    t.getSettings = function(){ var settings = nativeSettings(); settings.displaySurface = res.surface; return settings; };
  });
  var entry = {
    canvas: canvas, ctx: ctx, stream: stream, nativeStops: nativeStops,
    decoder: null, desc: null, needKey: true, last: null, drawnAt: 0
  };
  entry.refresh = setInterval(function(){
    if (entry.last && performance.now() - entry.drawnAt >= refreshMs) {
      entry.ctx.drawImage(entry.last, 0, 0, entry.canvas.width, entry.canvas.height);
      entry.drawnAt = performance.now();
    }
  }, refreshMs);
  active[res.token] = entry;
  pump({ token: res.token, frameURL: res.frameURL, seq: 0 });
  return stream;
}
var nativeUserMedia = navigator.mediaDevices.getUserMedia && navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
function chromeSource(c){ return c && typeof c === 'object' && c.mandatory && typeof c.mandatory === 'object' ? c.mandatory : null; }
navigator.mediaDevices.getUserMedia = function(constraints){
  var video = chromeSource(constraints && constraints.video), audio = chromeSource(constraints && constraints.audio);
  var source = (video || audio || {}).chromeMediaSource;
  if (source !== 'tab' && source !== 'desktop') return nativeUserMedia(constraints);
  var what = source === 'tab' ? 'tab' : 'screen';
  // WebKit has no per-page or system audio tap: the ferry carries video only.
  if (!video) return Promise.reject(new DOMException('Error starting ' + what + ' capture', 'NotSupportedError'));
  return handler.postMessage({ action: 'open', streamId: String(video.chromeMediaSourceId), source: source }).then(ferryStream, function(){
    throw new DOMException('Error starting ' + what + ' capture', 'AbortError');
  });
};
navigator.mediaDevices.getDisplayMedia = function(constraints){
  if (isActiveGetter && !isActiveGetter.call(activation)) {
    return Promise.reject(new DOMException('getDisplayMedia() requires user activation.', 'NotAllowedError'));
  }
  var id = String(Math.random()).slice(2);
  nativePending[id] = { constraints: constraints };
  return handler.postMessage({ action: 'pick', id: id }).then(function(res){
    var pending = nativePending[id];
    delete nativePending[id];
    // Without the hook's gesture, a native call would fail with InvalidAccessError, which pages
    // do not handle as a refusal.
    if (!res || res.mode === 'cancel' || (res.mode === 'system' && !pending.promise)) {
      throw new DOMException('Permission denied', 'NotAllowedError');
    }
    if (res.mode === 'system') return pending.promise;
    return ferryStream(res);
  }, function(){
    delete nativePending[id];
    throw new DOMException('Permission denied', 'NotAllowedError');
  });
};
})();
"""
}
