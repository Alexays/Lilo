import WebKit

/// Outcome of the chrome tab-share picker; `audio` is the window or screen's "Share audio too" toggle.
enum TabSharePickerChoice: Equatable {
    case tab(UUID)
    case system(audio: Bool)
    case cancel
}

/// Bridges the page-facing tab-share `getDisplayMedia`: WebKit only captures screens and windows, so a tab pick builds the stream
/// page-side from a canvas fed by `TabShareSessionController`; a screen or window pick runs WebKit's own picker.
@MainActor
final class TabShareBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let messageHandlerName = "liloTabShare"

    /// Presents the chrome tab picker, offering sound when the page asked for it; nil (headless) falls back to the system picker.
    var pickerPresenter: ((_ originHost: String, _ requester: WKWebView, _ wantsAudio: Bool) async -> TabSharePickerChoice)?
    /// Starts a frame-ferry session for the picked tab. Returns the shim reply payload
    /// (mode/token/width/height) or nil when the tab has no live engine.
    var sessionStarter: ((_ tabId: UUID, _ requester: WKWebView) -> [String: Any]?)?
    /// Runs the system screen or window picker and ferries the pick, with the Mac's sound when asked, which WebKit's own
    /// capture cannot share without echoing the call. Returns the shim reply payload, nil when cancelled.
    var screenStarter: ((_ requester: WKWebView, _ audio: Bool) async -> [String: Any]?)?
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
            let reply = await pick(originHost: origin.host, requester: requester, wantsAudio: body["audio"] as? Bool == true)
            if reply["mode"] as? String == "system", let id = body["id"] as? String {
                // The page's user activation was spent on the async picker; app-injected JS carries
                // a fresh one, and native getDisplayMedia also rejects a document without focus.
                requester.window?.makeFirstResponder(requester)
                _ = try? await requester.evaluateJavaScript(PageWorld.push("nativeDisplay", [id]), in: message.frameInfo, contentWorld: PageWorld.bridgeWorld)
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

    func pick(originHost: String, requester: WKWebView, wantsAudio: Bool = false) async -> [String: Any] {
        guard let pickerPresenter else { return ["mode": "system"] }
        switch await pickerPresenter(originHost, requester, wantsAudio) {
        case .system(let audio):
            // WebKit's own capture is sized in points, half the pixels of a Retina screen, at the frame rate the page asks.
            guard let screenStarter else { return ["mode": "system"] }
            return await screenStarter(requester, audio && wantsAudio) ?? ["mode": "cancel"]
        case .cancel:
            return ["mode": "cancel"]
        case .tab(let tabId):
            // A tab carries no sound: WebKit plays every tab through one process, which cannot be split per tab.
            guard let payload = sessionStarter?(tabId, requester) else { return ["mode": "cancel"] }
            return payload
        }
    }
}

// MARK: - Page module

extension TabShareBridge {
    /// `getDisplayMedia` for `PageWorld`, offering tab sharing; the native path stays reachable through the replaced
    /// original. `getUserMedia` with Chrome's `chromeMediaSource` redeems an extension's capture stream id on the same ferry.
    static let pageModule = #"""
function () {
if (typeof MediaDevices !== 'function' || !navigator.mediaDevices || !MediaDevices.prototype.getDisplayMedia) return;
// Cross-origin frames keep the native call, which enforces their display-capture permissions policy.
try { if (window.top !== window && window.top.location.origin !== location.origin) return; } catch (e) { return; }
var devices = navigator.mediaDevices, originals;
var Decoder = window.VideoDecoder, Chunk = window.EncodedVideoChunk, AudioCtx = window.AudioContext;
var NativeWorker = window.Worker, NativeBlob = window.Blob, objectURL = URL.createObjectURL, revokeURL = URL.revokeObjectURL;
var trusted = window.trustedTypes, createPolicy = trusted && trusted.createPolicy, workerPolicy;
// Captured before any page script runs, so the page cannot fake a user gesture.
var activation = navigator.userActivation;
var activationDesc = activation && Object.getOwnPropertyDescriptor(Object.getPrototypeOf(activation), 'isActive');
var isActiveGetter = activationDesc && activationDesc.get;
var active = {};
var nativePending = {};
// Pushed with a user gesture, which page code has no way to borrow.
lilo.on('nativeDisplay', function(id){
  var p = nativePending[id];
  if (p && !p.promise) p.promise = apply(originals.getDisplayMedia, devices, [p.constraints]);
});
// Meet's SDP flag puts a VP8 screen share in libwebrtc's legacy screenshare mode, held at 5 fps and 1 Mbps whatever the
// page sets (Chrome shares in AV1, which escapes it). Camera simulcast does not depend on it.
if (typeof RTCPeerConnection === 'function') {
  var peer = lilo.methods(RTCPeerConnection.prototype, { setRemoteDescription(description) {
    if (!description || typeof description.sdp !== 'string' || description.sdp.indexOf('a=x-google-flag:conference') === -1) {
      return apply(peer.setRemoteDescription, this, arguments);
    }
    var args = [{ type: description.type, sdp: description.sdp.replace(/a=x-google-flag:conference\r?\n/g, '') }];
    for (var i = 1; i < arguments.length; i++) args.push(arguments[i]);
    return apply(peer.setRemoteDescription, this, args);
  } });
}
// The track emits a frame only on requestFrame, and none for an unchanged canvas: on static content
// the encoder could neither refine a blurry first frame nor answer a keyframe request. Repaint at this interval.
var refreshMs = 200;
// Sound is scheduled this far ahead to absorb pull jitter; a block landing further ahead than the cap is dropped, so a
// stalled page cannot build up latency. The Mac's clock and the page's drift apart over a call: past twice the lead,
// blocks play slightly fast (inaudibly) until it is back, rather than piling up into a drop.
var audioLeadS = 0.04, audioMaxLeadS = 0.15, audioCatchUp = 1.005;
function endSession(token, notifyNative){
  var s = active[token];
  if (!s) return;
  delete active[token];
  clearInterval(s.refresh);
  if (s.worker) s.worker.terminate();
  if (s.decoder && s.decoder.state !== 'closed') s.decoder.close();
  if (s.last) s.last.close();
  if (s.audio) s.audio.ctx.close();
  if (notifyNative) lilo.send('liloTabShare', { action: 'stop', token: token });
  s.stream.getTracks().forEach(function(t){
    s.nativeStops.get(t)();
    if (!notifyNative) { try { t.dispatchEvent(new Event('ended')); } catch (e) {} }
  });
}
lilo.on('tabShareEnded', function(token){ endSession(token, false); });
apply(listen, window, ['pagehide', function(){
  for (var token in active) endSession(token, true);
}]);
// Frames arrive as H.264 in sequence; a decoder starts (or restarts after an error) on a keyframe,
// whose headers carry its config.
function configure(entry, codec, desc){
  if (entry.decoder && entry.decoder.state !== 'closed') entry.decoder.close();
  entry.decoder = new Decoder({
    output: function(frame){
      entry.ctx.drawImage(frame, 0, 0, entry.canvas.width, entry.canvas.height);
      entry.track.requestFrame();
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
// Samples arrive as mono Float32 blocks, each scheduled right after the previous one into the stream's audio track.
function pumpAudio(token, url){
  if (!active[token]) return;
  fetch(url, { cache: 'no-store' }).then(function(r){
    if (!active[token]) return;
    if (r.status === 410) return;
    if (r.status !== 200) { setTimeout(function(){ pumpAudio(token, url); }, 250); return; }
    var rate = parseFloat(r.headers.get('X-Lilo-Rate')) || 0;
    return r.arrayBuffer().then(function(data){
      var entry = active[token];
      if (!entry) return;
      var a = entry.audio, samples = new Float32Array(data), now = a.ctx.currentTime;
      if (a.next < now) a.next = now + audioLeadS;
      var lead = a.next - now;
      if (samples.length && lead <= audioMaxLeadS) {
        var buffer = a.ctx.createBuffer(1, samples.length, rate || a.rate);
        buffer.copyToChannel(samples, 0);
        var source = a.ctx.createBufferSource();
        source.buffer = buffer;
        if (lead > 2 * audioLeadS) source.playbackRate.value = audioCatchUp;
        source.connect(a.dest);
        source.start(a.next);
        a.next += buffer.duration / source.playbackRate.value;
      }
      pumpAudio(token, url);
    });
  }).catch(function(){
    if (active[token]) setTimeout(function(){ pumpAudio(token, url); }, 250);
  });
}
// The worker decodes straight into a VideoTrackGenerator and hands its track over: no canvas to draw and read back at every
// frame, and the page's main thread stays out of the loop. Same protocol and repaint rule as the canvas path below.
var workerSource = '(' + function(refreshMs){
  var generator = new VideoTrackGenerator(), writer = generator.writable.getWriter();
  var decoder = null, desc = null, needKey = true, last = null, drawnAt = 0, seq = 0, frameURL;
  function write(frame){
    drawnAt = performance.now();
    writer.write(new VideoFrame(frame, { timestamp: Math.round(drawnAt * 1000) })).catch(function(){});
  }
  function configure(codec, d){
    if (decoder && decoder.state !== 'closed') decoder.close();
    decoder = new VideoDecoder({
      output: function(frame){ if (last) last.close(); last = frame; write(frame); },
      error: function(){ decoder = null; needKey = true; }
    });
    decoder.configure({ codec: codec, description: Uint8Array.from(atob(d), function(c){ return c.charCodeAt(0); }),
                        hardwareAcceleration: 'prefer-hardware', optimizeForLatency: true });
    desc = d;
  }
  function pump(){
    fetch(frameURL + '&seq=' + seq + (needKey ? '&key=1' : ''), { cache: 'no-store' }).then(function(r){
      if (r.status === 410) { self.postMessage({ ended: true }); return; }
      if (r.status !== 200) { setTimeout(pump, 250); return; }
      var next = parseInt(r.headers.get('X-Lilo-Seq') || '0', 10), key = r.headers.get('X-Lilo-Key') === '1';
      var codec = r.headers.get('X-Lilo-Codec'), d = r.headers.get('X-Lilo-Desc');
      return r.arrayBuffer().then(function(data){
        if (key && (!decoder || desc !== d)) configure(codec, d);
        if (decoder && (key || !needKey)) {
          decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: next * 33333, data: data }));
          needKey = false;
        }
        seq = next;
        pump();
      });
    }).catch(function(){ setTimeout(pump, 250); });
  }
  setInterval(function(){ if (last && performance.now() - drawnAt >= refreshMs) write(last); }, refreshMs);
  self.onmessage = function(e){
    frameURL = e.data;
    pump();
    self.postMessage({ track: generator.track }, [generator.track]);
  };
} + ')(' + refreshMs + ')';
// A page enforcing Trusted Types refuses a plain URL: the worker's then goes through a policy of Lilo's own, made only then.
function startWorker(url){
  try { return new NativeWorker(url); } catch (e) {
    if (!createPolicy) throw e;
    workerPolicy = workerPolicy || apply(createPolicy, trusted, ['lilo-share', { createScriptURL: function(u){ return u; } }]);
    return new NativeWorker(workerPolicy.createScriptURL(url));
  }
}
// Resolves the worker's track, or null where it cannot run: a CSP refusing blob workers or Lilo's policy, or no
// VideoTrackGenerator. The canvas then carries the share.
function workerTrack(res){
  return new Promise(function(resolve){
    var url, worker;
    try {
      url = apply(objectURL, URL, [new NativeBlob([workerSource], { type: 'text/javascript' })]);
      worker = startWorker(url);
    } catch (e) { if (url) apply(revokeURL, URL, [url]); return resolve(null); }
    apply(revokeURL, URL, [url]);
    worker.onerror = function(){ worker.terminate(); resolve(null); };
    var handed = false;
    worker.onmessage = function(e){
      if (e.data.track) { handed = true; worker.onerror = null; resolve({ worker: worker, track: e.data.track }); }
      else if (handed) endSession(res.token, false);
      else { worker.terminate(); resolve(null); }
    };
    worker.postMessage(res.frameURL);
  });
}
function ferryStream(res, actx){
  return workerTrack(res).then(function(made){ return ferryStreamFrom(res, actx, made); });
}
function ferryStreamFrom(res, actx, made){
  var canvas = null, ctx = null, stream;
  if (made) {
    stream = new MediaStream([made.track]);
  } else {
    canvas = document.createElement('canvas');
    canvas.width = res.width;
    canvas.height = res.height;
    ctx = canvas.getContext('2d');
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, res.width, res.height);
    // One captured frame per decoded or repainted one: a 30 fps capture samples the canvas on its own clock.
    stream = canvas.captureStream(0);
  }
  var audio = null;
  if (actx && res.audioURL) {
    // Never connected to the context's destination: the share's sound must not play back locally.
    audio = { ctx: actx, dest: actx.createMediaStreamDestination(), next: 0, rate: res.sampleRate };
    stream.addTrack(audio.dest.stream.getAudioTracks()[0]);
  } else if (actx) {
    actx.close();
  }
  var nativeStops = new Map();
  stream.getTracks().forEach(function(t){
    nativeStops.set(t, t.stop.bind(t));
    t.stop = function(){ endSession(res.token, true); };
    if (t.kind !== 'video') return;
    t.contentHint = 'detail';
    var nativeSettings = t.getSettings.bind(t);
    t.getSettings = function(){ var settings = nativeSettings(); settings.displaySurface = res.surface; return settings; };
  });
  var entry = {
    canvas: canvas, ctx: ctx, stream: stream, track: stream.getVideoTracks()[0], nativeStops: nativeStops,
    decoder: null, desc: null, needKey: true, last: null, drawnAt: 0, audio: audio, worker: made && made.worker
  };
  active[res.token] = entry;
  if (!made) {
    entry.refresh = setInterval(function(){
      if (entry.last && performance.now() - entry.drawnAt >= refreshMs) {
        entry.ctx.drawImage(entry.last, 0, 0, entry.canvas.width, entry.canvas.height);
        entry.track.requestFrame();
        entry.drawnAt = performance.now();
      }
    }, refreshMs);
    pump({ token: res.token, frameURL: res.frameURL, seq: 0 });
  }
  if (audio) pumpAudio(res.token, res.audioURL);
  return stream;
}
function chromeSource(c){ return c && typeof c === 'object' && c.mandatory && typeof c.mandatory === 'object' ? c.mandatory : null; }
originals = lilo.methods(MediaDevices.prototype, {
getUserMedia(constraints){
  var video = chromeSource(constraints && constraints.video), audio = chromeSource(constraints && constraints.audio);
  var source = (video || audio || {}).chromeMediaSource;
  if (source !== 'tab' && source !== 'desktop') return apply(originals.getUserMedia, this, arguments);
  var what = source === 'tab' ? 'tab' : 'screen';
  // Extension streams carry no sound: the ferry's comes from the share picker's screen toggle.
  if (!video) return Promise.reject(new DOMException('Error starting ' + what + ' capture', 'NotSupportedError'));
  return lilo.post('liloTabShare', { action: 'open', streamId: String(video.chromeMediaSourceId), source: source }).then(function(res){ return ferryStream(res, null); }, function(){
    throw new DOMException('Error starting ' + what + ' capture', 'AbortError');
  });
},
getDisplayMedia(constraints){
  if (isActiveGetter && !isActiveGetter.call(activation)) {
    return Promise.reject(new DOMException('getDisplayMedia() requires user activation.', 'NotAllowedError'));
  }
  var id = String(Math.random()).slice(2);
  nativePending[id] = { constraints: constraints };
  var wantsAudio = !!(constraints && constraints.audio);
  // Made inside the page's gesture, which a context needs to play: the picker's wait spends it.
  var actx = wantsAudio && AudioCtx ? new AudioCtx() : null;
  if (actx) actx.resume();
  return lilo.post('liloTabShare', { action: 'pick', id: id, audio: wantsAudio }).then(function(res){
    var pending = nativePending[id];
    delete nativePending[id];
    // Without the hook's gesture, a native call would fail with InvalidAccessError, which pages
    // do not handle as a refusal.
    if (!res || res.mode === 'cancel' || (res.mode === 'system' && !pending.promise)) {
      if (actx) actx.close();
      throw new DOMException('Permission denied', 'NotAllowedError');
    }
    // A screen or window share is text: without a hint, the call's encoder keeps the frame rate
    // and lowers the resolution under load, blurring it. A hint the page sets wins.
    if (res.mode === 'system') {
      if (actx) actx.close();
      return pending.promise.then(function(stream){
        stream.getVideoTracks().forEach(function(t){ if (!t.contentHint) t.contentHint = 'detail'; });
        return stream;
      });
    }
    return ferryStream(res, actx);
  }, function(){
    delete nativePending[id];
    if (actx) actx.close();
    throw new DOMException('Permission denied', 'NotAllowedError');
  });
}
});
}
"""#
}
