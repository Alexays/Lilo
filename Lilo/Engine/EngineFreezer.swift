import WebKit

/// Installed into a page on its first freeze; native side calls the exposed globals to toggle.
@MainActor
enum CooperativeFreezer {
    /// Defines window.__liloFreeze()/__liloResume(): reports a hidden visibility state (firing visibilitychange) so pages throttle
    /// themselves, and pauses media. Unfrozen, it defers to the real visibility state so native background throttling still works.
    static let userScriptSource = """
    (function () {
      'use strict';
      if (window.__liloFreezeInstalled) return;
      window.__liloFreezeInstalled = true;
      var forced = false; // true => present the page as hidden
      var origVis = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
      var origHidden = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
      function nativeVisibility() {
        try { return origVis && origVis.get ? origVis.get.call(document) : 'visible'; } catch (e) { return 'visible'; }
      }
      function nativeHidden() {
        try { return origHidden && origHidden.get ? origHidden.get.call(document) : false; } catch (e) { return false; }
      }
      try {
        Object.defineProperty(document, 'visibilityState', {
          configurable: true,
          get: function () { return forced ? 'hidden' : nativeVisibility(); }
        });
        Object.defineProperty(document, 'hidden', {
          configurable: true,
          get: function () { return forced ? true : nativeHidden(); }
        });
      } catch (e) {}
      function fire() { try { document.dispatchEvent(new Event('visibilitychange')); } catch (e) {} }
      window.__liloFreeze = function () {
        forced = true; fire();
        try { document.querySelectorAll('video, audio').forEach(function (m) { try { m.pause(); } catch (e) {} }); } catch (e) {}
      };
      window.__liloResume = function () { forced = false; fire(); };
    })();
    """
}

/// Suspends and resumes a live background engine so a returning tab resumes instantly. `_suspendPage:` does the real work (bfcache);
/// media pause and the hidden-visibility flip cover pages WebKit declines to suspend.
@MainActor
final class CompositeFreezer {
    /// Pages WebKit holds suspended: most WKWebView calls on them raise NSInternalInconsistencyException,
    /// so code that only holds a raw web view (bridges replying to a page) checks here and skips.
    static let suspendedWebViews = NSHashTable<WKWebView>.weakObjects()

    func freeze(_ webView: WKWebView) {
        // Native, definitive: stop audio so a frozen tab is silent regardless of page cooperation.
        webView.pauseAllMediaPlayback()
        // Cooperative: tell the page it is hidden so it self-throttles (rAF/timers gate on visibility).
        // Sent before the suspension so the page handles it while it can still run.
        // Installed here rather than as a user script, so pages that never freeze never carry it.
        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(CooperativeFreezer.userScriptSource + ";window.__liloFreeze()")
        // WebKit flips its suspended flag synchronously, before the async reply.
        WebViewPrivateAccessors(webView).invoke("_suspendPage:") { _ in }
        Self.suspendedWebViews.add(webView)
    }

    func resume(_ webView: WKWebView) {
        // Same IPC channel as the script below, so the page is live again before it runs.
        WebViewPrivateAccessors(webView).invoke("_resumePage:") { _ in }
        Self.suspendedWebViews.remove(webView)
        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.__liloResume && window.__liloResume()")
    }
}
