import WebKit

/// Plays, pauses and skips a page's media from the sidebar's media card. The page's Media Session
/// handlers go first, as the page's own buttons would; bare media elements are the fallback.
extension WKWebViewTab {
    /// For `PageWorld`, main frame: it hooks Media Session before the page registers its handlers.
    static let mediaControlModule = #"""
    function () {
      if (window.top !== window || typeof MediaSession !== 'function') return;
      const handlers = create(null);
      let paused = [];
      const original = lilo.methods(MediaSession.prototype, { setActionHandler(action, handler) {
        const result = apply(original.setActionHandler, this, arguments);
        handlers[action] = handler;
        return result;
      } });
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

    /// `action` is play, pause, nexttrack or previoustrack.
    func controlMedia(_ action: String) {
        guard ["play", "pause", "nexttrack", "previoustrack"].contains(action), wake() else { return }
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
