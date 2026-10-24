import Foundation
import OSLog
import WebKit

/// Owns Picture-in-Picture for a tab's web view: the native private-SPI toggle with a
/// JavaScript page-video fallback, plus the auto-enter-on-background / restore-on-foreground policy.
@MainActor
final class PiPController {
    private static let logger = Logger(liloCategory: "pip")
    private let webView: WKWebView
    private let accessors: WebViewPrivateAccessors
    private var didAutoEnter = false

    init(webView: WKWebView) {
        self.webView = webView
        self.accessors = WebViewPrivateAccessors(webView)
    }

    /// Whether the page has a video that can enter Picture-in-Picture (private WKWebView API).
    var canToggle: Bool { accessors.bool("_canTogglePictureInPicture") ?? false }

    /// True while the predominant video is in the PiP window (private WKWebView API).
    var isActive: Bool { accessors.bool("_isPictureInPictureActive") ?? false }

    /// Toggle the predominant video into/out of the system Picture-in-Picture window.
    func toggle() {
        if canToggle, toggleNatively() { return }
        toggleUsingPageScript()
    }

    /// Auto-enter PiP when the tab is backgrounded, if it has a PiP-able video with active media.
    func autoEnterIfEligible(hasActiveMedia: Bool) {
        guard !isActive, hasActiveMedia else { return }
        if canToggle, toggleNatively() {
            didAutoEnter = true
            return
        }
        toggleUsingPageScript(markAutoEntered: true)
    }

    /// Undo only an auto-entered PiP when the tab returns to the foreground (leaves manual PiP alone).
    func restoreFromAuto() {
        guard didAutoEnter else { return }
        didAutoEnter = false
        if isActive, toggleNatively() { return }
        webView.evaluateJavaScript(Self.exitScript, completionHandler: nil)
    }

    private static let nativeToggle = NSSelectorFromString("_togglePictureInPicture")

    private func toggleNatively() -> Bool {
        guard webView.responds(to: Self.nativeToggle) else { return false }
        webView.perform(Self.nativeToggle)
        return true
    }

    /// Only reached when WebKit declines to designate a predominant video; the log tells how often
    /// that happens on real pages.
    private func toggleUsingPageScript(markAutoEntered: Bool = false) {
        webView.evaluateJavaScript(Self.toggleScript) { [weak self] result, error in
            let state = error == nil ? (result as? String ?? "unknown") : "error"
            Self.logger.info("page-script fallback: \(state, privacy: .public)")
            guard state == "entered" || state == "requested" else { return }
            if markAutoEntered { self?.didAutoEnter = true }
        }
    }

    private static let toggleScript = """
    (() => {
      const videos = Array.from(document.querySelectorAll('video'));
      const active = videos.find((video) => video.webkitPresentationMode === 'picture-in-picture');
      if (active && typeof active.webkitSetPresentationMode === 'function') {
        active.webkitSetPresentationMode('inline');
        return 'exited';
      }
      const candidates = videos
        .filter((video) => {
          if (video.disablePictureInPicture) return false;
          if (typeof video.webkitSetPresentationMode === 'function' &&
              typeof video.webkitSupportsPresentationMode === 'function' &&
              video.webkitSupportsPresentationMode('picture-in-picture')) {
            return true;
          }
          return document.pictureInPictureEnabled && typeof video.requestPictureInPicture === 'function';
        })
        .map((video) => {
          const rect = video.getBoundingClientRect();
          const area = Math.max(0, rect.width) * Math.max(0, rect.height);
          const score = (video.paused ? 0 : 1000000000) + area;
          return { video, score };
        })
        .sort((a, b) => b.score - a.score);
      const target = candidates[0]?.video;
      if (!target) return 'none';
      if (typeof target.webkitSetPresentationMode === 'function' &&
          typeof target.webkitSupportsPresentationMode === 'function' &&
          target.webkitSupportsPresentationMode('picture-in-picture')) {
        target.webkitSetPresentationMode('picture-in-picture');
        return 'entered';
      }
      target.requestPictureInPicture().catch(() => {});
      return 'requested';
    })()
    """

    private static let exitScript = """
    (() => {
      const active = Array.from(document.querySelectorAll('video'))
        .find((video) => video.webkitPresentationMode === 'picture-in-picture');
      if (active && typeof active.webkitSetPresentationMode === 'function') {
        active.webkitSetPresentationMode('inline');
        return 'exited';
      }
      if (document.pictureInPictureElement && document.exitPictureInPicture) {
        document.exitPictureInPicture().catch(() => {});
        return 'requested';
      }
      return 'none';
    })()
    """
}
