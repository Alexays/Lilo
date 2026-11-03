import AppKit

extension MainWindowController {
    /// Fades the window's traffic lights in and out with the sidebar, and holds them at the address
    /// bar's inset. The empty unified toolbar of the window centers them in the 52pt chrome header.
    @MainActor
    final class TrafficLightAnimator: NSObject {
        /// The address bar's left edge in the sidebar: the close button lines up with it.
        static let leadingInset: CGFloat = 10

        private var shown: Bool?
        private var shift: CGFloat = 0
        private var heldX: [ObjectIdentifier: CGFloat] = [:]

        /// AppKit puts the buttons back at its own spot on every title change, resize and full-screen
        /// transition, so each such move is undone, before Core Animation commits it.
        func holdAtLeadingInset(window: NSWindow) {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            guard let close = buttons.first else { return }
            shift = close.frame.minX - Self.leadingInset
            for button in buttons {
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(buttonMoved(_:)), name: NSView.frameDidChangeNotification, object: button)
                hold(button)
            }
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
            guard heldX[id] != button.frame.minX else { return }
            let x = button.frame.minX - shift
            heldX[id] = x
            button.setFrameOrigin(NSPoint(x: x, y: button.frame.minY))
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
