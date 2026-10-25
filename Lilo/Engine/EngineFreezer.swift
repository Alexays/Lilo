import WebKit

/// The cooperative half of a freeze, for `PageWorld`: reports a hidden visibility state (firing visibilitychange) so pages throttle
/// themselves, and pauses media. Unfrozen, it defers to the real visibility state so native background throttling still works.
@MainActor
enum CooperativeFreezer {
    static let pageModule = #"""
    function () {
      if (window.top !== window) return;
      let forced = false, visibility;
      const fire = () => { try { apply(dispatch, doc, [new NativeEvent('visibilitychange')]); } catch (e) {} };
      lilo.on('freeze', () => {
        // Swapped on the first freeze only: pages that never freeze keep WebKit's own getters.
        visibility = visibility || lilo.accessors(Document.prototype, {
          get visibilityState() { return forced ? 'hidden' : apply(visibility.visibilityState, this, []); },
          get hidden() { return forced || apply(visibility.hidden, this, []); },
        });
        forced = true;
        fire();
        try { document.querySelectorAll('video, audio').forEach(media => { try { media.pause(); } catch (e) {} }); } catch (e) {}
      });
      lilo.on('resume', () => { forced = false; fire(); });
    }
    """#
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
        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("freeze"), in: nil, in: PageWorld.bridgeWorld)
        // WebKit flips its suspended flag synchronously, before the async reply.
        WebViewPrivateAccessors(webView).invoke("_suspendPage:") { _ in }
        Self.suspendedWebViews.add(webView)
    }

    func resume(_ webView: WKWebView) {
        // Same IPC channel as the script below, so the page is live again before it runs.
        WebViewPrivateAccessors(webView).invoke("_resumePage:") { _ in }
        Self.suspendedWebViews.remove(webView)
        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("resume"), in: nil, in: PageWorld.bridgeWorld)
    }
}
