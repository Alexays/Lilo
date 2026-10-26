import Foundation

/// Grows a pinned page's inner scroller or viewport iframe to full height for the duration of a full-page capture.
/// Frames coordinate via `postMessage` (a parent's only handle on a cross-origin child); never-navigating frames cannot take part.
enum PageSnapshotExpansion {
    /// Random per app run. A page can read this off an in-flight message and forge a request, but
    /// only while the user is taking a screenshot, and all it learns is the content height of a
    /// frame that same capture is about to render anyway.
    private static let token = UUID().uuidString

    /// Injected into the main frame and every known subframe when a capture starts, never before:
    /// this leaves no listener behind on pages the user is merely browsing. Idempotent, so a second
    /// capture on the same document re-injects harmlessly.
    static let installJS = """
    (function () {
      if (window.__liloSnapshotReady) return;
      window.__liloSnapshotReady = true;

      var TOKEN = '\(token)';
      var undo = [];
      // setProperty re-serialises the style attribute, so the original text is put back verbatim.
      var attrs = [];
      // Unclipping a scroller resets its offset, which restoring its styles alone does not bring back.
      var offsets = [];

      function documentHeight() {
        return Math.max(
          document.documentElement ? document.documentElement.scrollHeight : 0,
          document.body ? document.body.scrollHeight : 0
        );
      }

      function force(el, prop, value) {
        if (!attrs.some(function (entry) { return entry[0] === el; })) attrs.push([el, el.getAttribute('style')]);
        undo.push([el, prop, el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)]);
        el.style.setProperty(prop, value, 'important');
      }

      // An ancestor that clips, locks a height, or takes itself out of flow keeps the document from
      // growing however tall the thing inside it is told to be.
      function unclip(from) {
        for (var el = from; el; el = el.parentElement) {
          force(el, 'height', 'auto');
          force(el, 'max-height', 'none');
          // A `flex: 1 1 0; min-height: 0` item stays as tall as its column, not its content.
          force(el, 'min-height', 'auto');
          // Next to a hidden or scrolling x axis, a visible y axis computes to auto and stays a scroller.
          var overflowX = getComputedStyle(el).overflowX;
          if (overflowX !== 'visible' && overflowX !== 'clip') force(el, 'overflow-x', 'clip');
          force(el, 'overflow-y', 'visible');
          var position = getComputedStyle(el).position;
          if (position === 'fixed' || position === 'absolute') force(el, 'position', 'static');
        }
      }

      function dominantScroller() {
        var best = null, bestArea = 0, all = document.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) {
          var el = all[i], style = getComputedStyle(el);
          if (style.overflowY !== 'scroll' && style.overflowY !== 'auto') continue;
          if (el.scrollHeight <= el.clientHeight + 5) continue;
          var rect = el.getBoundingClientRect(), area = rect.width * rect.height;
          if (rect.width < 100 || rect.height < 100 || area <= bestArea) continue;
          bestArea = area; best = el;
        }
        return best ? { el: best, area: bestArea } : null;
      }

      function dominantFrame() {
        var best = null, bestArea = 0, frames = document.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
          // A transparent frame can outsize the real scroller: LinkedIn keeps a viewport-sized preload one.
          if (!frames[i].checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
          var rect = frames[i].getBoundingClientRect(), area = rect.width * rect.height;
          if (rect.width < 100 || rect.height < 100 || area <= bestArea) continue;
          bestArea = area; best = frames[i];
        }
        return best ? { el: best, area: bestArea } : null;
      }

      function ask(frame, request) {
        return new Promise(function (resolve) {
          var target = frame.contentWindow;
          if (!target) return resolve(0);
          var timer = setTimeout(function () { done(0); }, 400);
          function done(height) {
            clearTimeout(timer);
            window.removeEventListener('message', onReply, true);
            resolve(typeof height === 'number' ? height : 0);
          }
          function onReply(event) {
            // Window identity, not origin: it is the only thing that recognises a cross-origin child.
            if (event.source !== target) return;
            var data = event.data;
            if (!data || data.liloSnapshot !== TOKEN || data.reply !== request) return;
            done(data.height);
          }
          window.addEventListener('message', onReply, true);
          target.postMessage({ liloSnapshot: TOKEN, request: request }, '*');
        });
      }

      async function expand() {
        if (undo.length) return documentHeight();
        if (documentHeight() > window.innerHeight + 10) return documentHeight();

        var frame = dominantFrame(), scroller = dominantScroller();
        if (frame && (!scroller || frame.area >= scroller.area)) {
          var height = await ask(frame.el, 'expand');
          if (height > 0) {
            unclip(frame.el.parentElement);
            force(frame.el, 'height', height + 'px');
            force(frame.el, 'max-height', 'none');
            var position = getComputedStyle(frame.el).position;
            if (position === 'fixed' || position === 'absolute') force(frame.el, 'position', 'static');
            return documentHeight();
          }
        }
        if (scroller) {
          offsets.push([scroller.el, scroller.el.scrollTop]);
          unclip(scroller.el);
        }
        return documentHeight();
      }

      function restore() {
        var frames = document.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) ask(frames[i], 'restore');
        // Backwards: a property forced twice has to land back on its oldest recorded value.
        for (var j = undo.length - 1; j >= 0; j--) {
          var entry = undo[j];
          if (entry[2]) entry[0].style.setProperty(entry[1], entry[2], entry[3]);
          else entry[0].style.removeProperty(entry[1]);
        }
        undo = [];
        for (var k = 0; k < attrs.length; k++) {
          if (attrs[k][1] === null) attrs[k][0].removeAttribute('style');
          else attrs[k][0].setAttribute('style', attrs[k][1]);
        }
        attrs = [];
        for (var m = 0; m < offsets.length; m++) offsets[m][0].scrollTop = offsets[m][1];
        offsets = [];
      }

      window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || data.liloSnapshot !== TOKEN || !data.request) return;
        function reply(height) {
          if (event.source) {
            event.source.postMessage({ liloSnapshot: TOKEN, reply: data.request, height: height }, '*');
          }
        }
        if (data.request === 'expand') expand().then(reply, function () { reply(0); });
        else { restore(); reply(0); }
      }, true);
    })();
    """

    /// Body of an async function: resolves once the main frame, and through it every frame below,
    /// has expanded and laid out. There is no page-callable entry point on purpose, so a page cannot
    /// drive this on its own.
    static let expandJS = """
    var height = await new Promise(function (resolve) {
      var timer = setTimeout(function () { finish(0); }, 2000);
      function finish(value) {
        clearTimeout(timer);
        window.removeEventListener('message', onReply, true);
        resolve(value);
      }
      function onReply(event) {
        var data = event.data;
        if (event.source !== window) return;
        if (!data || data.liloSnapshot !== '\(token)' || data.reply !== 'expand') return;
        finish(data.height);
      }
      window.addEventListener('message', onReply, true);
      window.postMessage({ liloSnapshot: '\(token)', request: 'expand' }, '*');
    });
    // Reading a layout property has already flushed layout by now; this only gives painting a chance.
    \(waitForPaintJS)
    return height;
    """

    /// Waits two frames for a paint. A frame the compositor never paints (an occluded window, a web view
    /// off screen) never fires requestAnimationFrame, so the timeout keeps this from waiting forever.
    static let waitForPaintJS = """
    await new Promise(function (resolve) {
      var settled = false;
      function go() { if (!settled) { settled = true; resolve(); } }
      requestAnimationFrame(function () { requestAnimationFrame(go); });
      setTimeout(go, 100);
    });
    """

    static let restoreJS = "window.postMessage({ liloSnapshot: '\(token)', request: 'restore' }, '*');"
}
