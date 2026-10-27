import WebKit

/// Plays, pauses and skips a page's media from the sidebar's media card, and toggles a call's microphone
/// and camera from its call card. The page's Media Session handlers go first, as the page's own buttons
/// would; bare media elements (or WebKit's capture state, for a call) are the fallback.
extension WKWebViewTab {
    /// What a page in a call told Media Session: its microphone and camera state (nil until it says) and
    /// which of togglemicrophone, togglecamera and hangup it handles.
    struct CallControls: Equatable {
        var microphoneActive: Bool?
        var cameraActive: Bool?
        var actions: Set<String> = []
    }

    static let callActions = ["togglemicrophone", "togglecamera", "hangup"]

    /// For `PageWorld`, main frame: it hooks Media Session before the page registers its handlers.
    static let mediaControlModule = #"""
    function () {
      if (window.top !== window || typeof MediaSession !== 'function') return;
      const handlers = create(null);
      let paused = [], microphone = null, camera = null;
      const call = () => stringify({ microphone, camera, togglemicrophone: !!handlers.togglemicrophone,
                                     togglecamera: !!handlers.togglecamera, hangup: !!handlers.hangup });
      // A page that never touches the call controls sends nothing.
      let reported = call();
      const report = () => {
        const state = call();
        if (state !== reported) { reported = state; lilo.send('liloCall', parse(state)); }
      };
      const hooks = { setActionHandler(action, handler) {
        let result;
        // WebKit rejects hangup; a call page registering one anyway still gets the call card's button.
        try { result = apply(original.setActionHandler, this, arguments); } catch (e) { if (action !== 'hangup') throw e; }
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
      lilo.on('media', action => {
        if (action === 'tracks') return !!(handlers.nexttrack || handlers.previoustrack);
        if (handlers[action]) {
          try { handlers[action]({ action }); return true; } catch (e) {}
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

    /// `action` is play, pause, nexttrack, previoustrack, or one of `callActions` the page handles.
    func controlMedia(_ action: String) {
        guard ["play", "pause", "nexttrack", "previoustrack"].contains(action) || callControls.actions.contains(action), wake() else { return }
        wkWebView.evaluateJavaScript(PageWorld.push("media", [action]), in: nil, in: PageWorld.bridgeWorld) { [weak self] _ in
            // Media in frames the script does not reach still stops; it runs after the script so the
            // script's own list of what it paused stays whole for the next play.
            if action == "pause" { self?.wkWebView.pauseAllMediaPlayback() }
        }
    }

    /// Whether the page registered Media Session next or previous track handlers.
    /// Lilo asks this on its own, not on a user action: the page gets no user activation from it.
    func hasMediaTrackControls() async -> Bool {
        await withCheckedContinuation { continuation in
            WebViewPrivateAccessors(wkWebView).evaluateWithoutUserGesture(PageWorld.push("media", ["tracks"]), in: nil, in: PageWorld.bridgeWorld) {
                continuation.resume(returning: $0 as? Bool ?? false)
            }
        }
    }
}
