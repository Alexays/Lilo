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
    }

    static let callActions = ["togglemicrophone", "togglecamera", "hangup"]

    /// For `PageWorld`, main frame: it hooks Media Session before the page registers its handlers.
    static let mediaControlModule = #"""
    function () {
      if (window.top !== window || typeof MediaSession !== 'function') return;
      const handlers = create(null);
      let paused = [], microphone = null, camera = null;
      const call = () => stringify({ microphone, camera, togglemicrophone: !!handlers.togglemicrophone,
                                     togglecamera: !!handlers.togglecamera, hangup: !!handlers.hangup,
                                     tracks: !!(handlers.nexttrack || handlers.previoustrack), pip: !!handlers.enterpictureinpicture });
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
