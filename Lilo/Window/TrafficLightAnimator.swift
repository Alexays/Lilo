import AppKit

extension MainWindowController {
    /// Fades the window's traffic lights in and out with the sidebar, and moves them in from the corner
    /// where the sidebar asks. Elsewhere they stay where the empty unified toolbar of the window centers
    /// them, in the 52pt chrome header.
    @MainActor
    final class TrafficLightAnimator: NSObject {

        private var shown: Bool?
        private var observed = false
        private var offset = CGSize.zero
        /// Where AppKit puts each button, and where it was moved to.
        private var appKitOrigins: [ObjectIdentifier: NSPoint] = [:]
        private var heldOrigins: [ObjectIdentifier: NSPoint] = [:]

        /// Puts the close button `inset` from the window's left edge, and as far from its top when `square`;
        /// nil leaves them to AppKit. AppKit puts the buttons back at its own spot on every title change,
        /// resize and full-screen transition, so each such move is undone, before Core Animation commits it.
        func place(window: NSWindow, inset: CGFloat?, square: Bool) {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            if !observed {
                observed = true
                for button in buttons {
                    button.postsFrameChangedNotifications = true
                    NotificationCenter.default.addObserver(self, selector: #selector(buttonMoved(_:)), name: NSView.frameDidChangeNotification, object: button)
                }
            }
            guard let close = buttons.first, let titlebar = unsafe close.superview else { return }
            let appKit = appKitOrigins[ObjectIdentifier(close)] ?? close.frame.origin
            let appKitTop = titlebar.isFlipped ? appKit.y : titlebar.bounds.height - appKit.y - close.frame.height
            let next = inset.map { CGSize(width: $0 - appKit.x, height: square ? appKitTop - $0 : 0) } ?? .zero
            guard next != offset || heldOrigins.isEmpty else { return }
            offset = next
            buttons.forEach(hold)
        }

        @objc private func buttonMoved(_ notification: Notification) {
            guard let button = notification.object as? NSView else { return }
            // Moved back during AppKit's own frame change, the button would not stay: the run loop runs
            // the block once that change is over, still ahead of the commit.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self, weak button] in
                MainActor.assumeIsolated {
                    if let button { self?.hold(button) }
                }
            }
        }

        private func hold(_ button: NSView) {
            let id = ObjectIdentifier(button)
            if heldOrigins[id] != button.frame.origin { appKitOrigins[id] = button.frame.origin }
            guard let appKit = appKitOrigins[id] else { return }
            let up = unsafe button.superview?.isFlipped == true ? -offset.height : offset.height
            let origin = NSPoint(x: appKit.x + offset.width, y: appKit.y + up)
            heldOrigins[id] = origin
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }

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
