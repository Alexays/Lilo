import AppKit

extension MainWindowController {
    /// Fades the window's traffic lights in and out with the sidebar. AppKit places them: the empty
    /// unified toolbar of the window centers them in the 52pt chrome header.
    @MainActor
    final class TrafficLightAnimator {
        private var shown: Bool?

        func sync(window: NSWindow, visible: Bool, animated: Bool, duration: TimeInterval) {
            // Full screen reveals them in its own title bar, over the chrome.
            let show = visible || window.styleMask.contains(.fullScreen)
            guard show != shown else { return }
            shown = show
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            // A transparent button still takes clicks: hidden ones must leave the view tree's hit test.
            if show { buttons.forEach { $0.isHidden = false } }
            guard animated else {
                for button in buttons {
                    button.alphaValue = show ? 1 : 0
                    button.isHidden = !show
                }
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for button in buttons { button.animator().alphaValue = show ? 1 : 0 }
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.shown == false else { return }
                    buttons.forEach { $0.isHidden = true }
                }
            })
        }
    }
}
