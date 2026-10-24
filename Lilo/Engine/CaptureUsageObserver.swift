import Foundation
import WebKit

/// Observes a tab's camera, microphone and screen-share capture state (public KVO plus the private `_displayCaptureState`)
/// and reports a deduped `WebPermissionUsageState` for the capture badge.
@MainActor
final class CaptureUsageObserver: NSObject {
    private let webView: WKWebView
    private let onChange: (WKWebViewTab.WebPermissionUsageState) -> Void
    private var observations: [NSKeyValueObservation] = []
    private var displayCaptureRegistered = false

    /// Last state handed to `onChange`, sticky high: an off transition commits only after `clearDebounce`, absorbing WebKit's
    /// transient `.none` blips mid-call so the badge and the retention/freeze guards keyed on it don't flicker.
    private var committed: WKWebViewTab.WebPermissionUsageState = .none
    private var pendingClear: Task<Void, Never>?
    private static let clearDebounce: Duration = .seconds(2)

    init(webView: WKWebView, onChange: @escaping (WKWebViewTab.WebPermissionUsageState) -> Void) {
        self.webView = webView
        self.onChange = onChange
        super.init()
    }

    func start() {
        let update: @Sendable (WKWebView, NSKeyValueObservedChange<WKMediaCaptureState>) -> Void = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.recompute() }
        }
        observations = [
            webView.observe(\.cameraCaptureState, options: [.initial, .new], changeHandler: update),
            webView.observe(\.microphoneCaptureState, options: [.initial, .new], changeHandler: update)
        ]
        // _displayCaptureState (screen-share state) is private; observe via string-key KVO, only when
        // WebKit still has it, since KVO on a missing key raises.
        guard webView.responds(to: NSSelectorFromString("_displayCaptureState")) else { return }
        webView.addObserver(self, forKeyPath: "_displayCaptureState", options: [.new], context: nil)
        displayCaptureRegistered = true
    }

    func stop() {
        pendingClear?.cancel()
        pendingClear = nil
        if displayCaptureRegistered {
            webView.removeObserver(self, forKeyPath: "_displayCaptureState")
            displayCaptureRegistered = false
        }
        observations.removeAll()
    }

    // swiftlint:disable:next block_based_kvo
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "_displayCaptureState" {
            Task { @MainActor [weak self] in self?.recompute() }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func currentUsage() -> WKWebViewTab.WebPermissionUsageState {
        let displayActive = (WebViewPrivateAccessors(webView).int("_displayCaptureState") ?? 0) != 0
        return Self.compute(
            camera: webView.cameraCaptureState,
            microphone: webView.microphoneCaptureState,
            displayCaptureActive: displayActive
        )
    }

    private func recompute() {
        let target = currentUsage()
        // Sticky-high merge: turning a device ON wins immediately; turning one OFF is held at its
        // committed value (the timer below commits the real state once it has stayed off).
        var next = committed
        var hasDowngrade = false
        for keep in [\WKWebViewTab.WebPermissionUsageState.usesCamera,
                     \.usesMicrophone,
                     \.usesScreen] {
            if target[keyPath: keep] {
                next[keyPath: keep] = true
            } else if committed[keyPath: keep] {
                hasDowngrade = true // keep `next` ON until the downgrade debounce elapses
            }
        }
        // Muted is cosmetic (no retention impact), so it is reflected without debounce.
        next.isMicrophoneMuted = target.isMicrophoneMuted

        if next != committed { commit(next) }

        if hasDowngrade {
            // Restart the window on every fresh downgrade so each gets the full grace.
            pendingClear?.cancel()
            pendingClear = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.clearDebounce)
                guard let self, !Task.isCancelled else { return }
                self.pendingClear = nil
                self.commit(self.currentUsage()) // commit the honest state now the window has elapsed
            }
        } else {
            pendingClear?.cancel()
            pendingClear = nil
        }
    }

    private func commit(_ state: WKWebViewTab.WebPermissionUsageState) {
        guard state != committed else { return }
        committed = state
        onChange(state)
    }

    /// Pure mapping from raw capture inputs to the badge state.
    static func compute(
        camera: WKMediaCaptureState,
        microphone: WKMediaCaptureState,
        displayCaptureActive: Bool
    ) -> WKWebViewTab.WebPermissionUsageState {
        WKWebViewTab.WebPermissionUsageState(
            usesCamera: camera != .none,
            usesMicrophone: microphone != .none,
            isMicrophoneMuted: microphone == .muted,
            usesScreen: displayCaptureActive
        )
    }
}
