import WebKit

/// Plays, pauses and skips a page's media from the sidebar's media card, and toggles a call's microphone
/// and camera from its call card. The page's Media Session handlers go first, as the page's own buttons
/// would; bare media elements (or WebKit's capture state, for a call) are the fallback.
extension WKWebViewTab {
    /// What a page in a call told Media Session: its microphone and camera state (nil until it says) and
    /// which of togglemicrophone, togglecamera and hangup it handles; also whether it handles next or previous track.
    struct CallControls: Equatable {
        var microphoneActive: Bool?
        var cameraActive: Bool?
        var actions: Set<String> = []
        var hasTrackControls = false
        /// The page handles `enterpictureinpicture`: it opens its own PiP window when asked.
        var hasPictureInPictureAction = false
        /// The page holds a connected WebRTC peer: a call, though it may register no Media Session action and
        /// capture nothing (Meet's companion mode).
        var hasLiveConnection = false
        /// The page holds a connected WebRTC peer, data channels alone included, or a Web Lock: as in Chrome, an idle freeze
        /// spares it, so a web chat or game stays connected and other tabs waiting for the lock are not held up.
        var hasPeerConnection = false
        var holdsWebLock = false

        /// A call even without capture: the page offers a hangup or holds a live connection.
        var isCall: Bool { actions.contains("hangup") || hasLiveConnection }
    }

    static let callActions = ["togglemicrophone", "togglecamera", "hangup"]

    /// For `PageWorld`, main frame: it hooks Media Session before the page registers its handlers.
    static let mediaControlModule = #"""
    function () {
      if (window.top !== window || typeof MediaSession !== 'function') return;
      const handlers = create(null);
      let paused = [], microphone = null, camera = null, rtc = false, peer = false, locks = 0;
      const call = () => stringify({ microphone, camera, togglemicrophone: !!handlers.togglemicrophone,
                                     togglecamera: !!handlers.togglecamera, hangup: !!handlers.hangup,
                                     tracks: !!(handlers.nexttrack || handlers.previoustrack), pip: !!handlers.enterpictureinpicture, rtc,
                                     peer, lock: locks > 0 });
      // A page that never touches these controls sends nothing.
      let reported = call();
      const report = () => {
        const state = call();
        if (state !== reported) { reported = state; lilo.send('liloCall', parse(state)); }
      };
      const hooks = { setActionHandler(action, handler) {
        let result;
        // WebKit rejects hangup and enterpictureinpicture; a call page registering one anyway still gets the call card's
        // button, or its PiP window opened when its tab is left.
        try { result = apply(original.setActionHandler, this, arguments); } catch (e) { if (action !== 'hangup' && action !== 'enterpictureinpicture') throw e; }
        handlers[action] = handler;
        report();
        return result;
      } };
      if (MediaSession.prototype.setMicrophoneActive) hooks.setMicrophoneActive = function setMicrophoneActive(active) {
        const result = apply(original.setMicrophoneActive, this, arguments);
        microphone = !!active;
        report();
        return result;
      };
      if (MediaSession.prototype.setCameraActive) hooks.setCameraActive = function setCameraActive(active) {
        const result = apply(original.setCameraActive, this, arguments);
        camera = !!active;
        report();
        return result;
      };
      const original = lilo.methods(MediaSession.prototype, hooks);
      // A call may register no Media Session action and capture nothing (Meet's companion mode): a connected
      // WebRTC peer tells it. Every peer of a call gets a remote description, so the hook sees each one; the
      // constructor stays WebKit's own.
      if (typeof RTCPeerConnection === 'function') {
        const peers = new Set(), transceivers = RTCPeerConnection.prototype.getTransceivers;
        // A call carries audio or video: a data channel alone is a file transfer or a game. A brief disconnection keeps
        // the connection; only a failed or closed one ends it.
        const settle = () => {
          rtc = peer = false;
          for (const connection of peers) {
            const state = connection.connectionState;
            if (state === 'closed' || state === 'failed') peers.delete(connection);
            else if (state === 'connected' || state === 'disconnected') {
              peer = true;
              if (apply(transceivers, connection, []).length > 0) rtc = true;
            }
          }
          report();
        };
        const peerOriginal = lilo.methods(RTCPeerConnection.prototype, { setRemoteDescription() {
          if (!peers.has(this)) {
            peers.add(this);
            apply(listen, this, ['connectionstatechange', settle]);
          }
          return apply(peerOriginal.setRemoteDescription, this, arguments);
        },
        // Closing fires no state change event.
        close() {
          const result = apply(peerOriginal.close, this, arguments);
          settle();
          return result;
        } });
      }
      // A lock counts from its grant until what the page's callback returns settles, which is when WebKit releases it. The page's
      // own promise is left untouched, so a rejected request still reaches unhandledrejection.
      if (typeof LockManager === 'function') {
        const then = NativePromise.prototype.then;
        const lockOriginal = lilo.methods(LockManager.prototype, { request() {
          const args = [], last = arguments.length - 1, callback = arguments[last];
          for (let i = 0; i < arguments.length; i++) args[i] = arguments[i];
          if (typeof callback === 'function') args[last] = function (lock) {
            if (!lock) return apply(callback, this, arguments);
            locks++;
            report();
            const release = () => { locks--; report(); };
            let result, settle;
            try { result = apply(callback, this, arguments); } catch (e) { release(); throw e; }
            const held = new NativePromise(resolve => { settle = resolve; });
            // Own members keep WebKit's adoption of `held`, and this one, off a Promise.prototype the page may patch.
            defineProperty(held, 'then', { value: then });
            defineProperty(held, 'constructor', { value: undefined });
            settle(result);
            apply(then, held, [release, release]);
            return held;
          };
          return apply(lockOriginal.request, this, args);
        } });
      }
      // WebKit divides the RTP audio level (dBov) by 20 in integers: every level reads 1, 0.1, 0.01... A call page then sees
      // everyone speaking loudly and keeps its speaking animations and tile layout busy. A band's middle is what Chrome reports.
      if (typeof RTCRtpReceiver === 'function') {
        const log10 = Math.log10, round = Math.round, abs = Math.abs, bandMiddle = 0.31622776601683794;
        const level = sources => {
          for (const source of sources) {
            const value = source.audioLevel;
            if (value > 0 && abs(value / 10 ** round(log10(value)) - 1) < 1e-9) source.audioLevel = value * bandMiddle;
          }
          return sources;
        };
        const receiverOriginal = lilo.methods(RTCRtpReceiver.prototype, {
          getContributingSources() { return level(apply(receiverOriginal.getContributingSources, this, arguments)); },
          getSynchronizationSources() { return level(apply(receiverOriginal.getSynchronizationSources, this, arguments)); },
        });
      }
      lilo.on('media', (action, reason) => {
        if (handlers[action]) {
          const details = { action };
          if (reason) details.enterPictureInPictureReason = reason;
          try { handlers[action](details); return true; } catch (e) {}
        }
        if (action === 'pause') {
          paused = Array.prototype.filter.call(document.querySelectorAll('video, audio'), media => !media.paused);
          paused.forEach(media => media.pause());
        } else if (action === 'play') {
          paused.forEach(media => { try { media.play().catch(() => {}); } catch (e) {} });
          paused = [];
        }
        return true;
      });
    }
    """#

    /// Asks the page for its Document PiP window through its Media Session handler, as Chrome does when a call tab
    /// is left. As a `useraction`: the user left the tab with auto PiP on, and Meet keeps its automatic opening for
    /// some accounts only, where its menu's opening works for all.
    func enterDocumentPictureInPicture() {
        guard callControls.hasPictureInPictureAction, wake() else { return }
        wkWebView.evaluateJavaScript(PageWorld.push("media", ["enterpictureinpicture", "useraction"]), in: nil, in: PageWorld.bridgeWorld)
    }

    /// `action` is play, pause, nexttrack, previoustrack, or one of `callActions` the page handles.
    func controlMedia(_ action: String) {
        guard ["play", "pause", "nexttrack", "previoustrack"].contains(action) || callControls.actions.contains(action), wake() else { return }
        wkWebView.evaluateJavaScript(PageWorld.push("media", [action]), in: nil, in: PageWorld.bridgeWorld) { [weak self] _ in
            // Media in frames the script does not reach still stops; it runs after the script so the
            // script's own list of what it paused stays whole for the next play.
            if action == "pause" { self?.wkWebView.pauseAllMediaPlayback() }
        }
    }
}
