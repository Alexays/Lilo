import WebKit

/// Plays, pauses and skips a page's media from the sidebar's media card. The page's Media Session
/// handlers go first, as the page's own buttons would; bare media elements are the fallback.
extension WKWebViewTab {
    /// Page world, main frame: it hooks `navigator.mediaSession` before the page registers its handlers.
    static let mediaControlSource = """
    (function () {
      'use strict';
      var handlers = {};
      var session = navigator.mediaSession;
      if (session && typeof session.setActionHandler === 'function') {
        var setActionHandler = session.setActionHandler;
        session.setActionHandler = function (action, handler) {
          handlers[action] = handler;
          return setActionHandler.apply(this, arguments);
        };
      }
      var paused = [];
      window.__liloMedia = function (action) {
        if (action === 'tracks') return !!(handlers.nexttrack || handlers.previoustrack);
        if (handlers[action]) {
          try { handlers[action]({ action: action }); return true; } catch (e) {}
        }
        if (action === 'pause') {
          paused = Array.prototype.filter.call(document.querySelectorAll('video, audio'), function (m) { return !m.paused; });
          paused.forEach(function (m) { m.pause(); });
        } else if (action === 'play') {
          paused.forEach(function (m) { try { m.play().catch(function () {}); } catch (e) {} });
          paused = [];
        }
        return true;
      };
    })();
    """

    /// `action` is play, pause, nexttrack or previoustrack.
    func controlMedia(_ action: String) {
        guard ["play", "pause", "nexttrack", "previoustrack"].contains(action), wake() else { return }
        wkWebView.evaluateJavaScript("window.__liloMedia && window.__liloMedia('\(action)')") { [weak self] _, _ in
            // Media in frames the script does not reach still stops; it runs after the script so the
            // script's own list of what it paused stays whole for the next play.
            if action == "pause" { self?.wkWebView.pauseAllMediaPlayback() }
        }
    }

    /// Whether the page registered Media Session next or previous track handlers.
    /// Lilo asks this on its own, not on a user action: the page gets no user activation from it.
    func hasMediaTrackControls() async -> Bool {
        await withCheckedContinuation { continuation in
            WebViewPrivateAccessors(wkWebView).evaluateWithoutUserGesture("!!(window.__liloMedia && window.__liloMedia('tracks'))") {
                continuation.resume(returning: $0 as? Bool ?? false)
            }
        }
    }
}
