import AppKit

/// The Little window's panel: it joins every Space and sits beside a full-screen window, so it shows over the
/// full-screen Space the user is in instead of switching to Lilo's own. It takes key focus like a window.
final class LittlePanel: NSPanel {
    /// Whether an Escape the page would otherwise get closes the window.
    var shouldCloseOnEscape: (() -> Bool)?

    init(contentRect: NSRect) {
        // `.nonactivatingPanel` is what lets a panel appear over another app's full-screen Space; the controller
        // activates the app itself when the window opens from a shortcut.
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tabbingMode = .disallowed
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // An empty toolbar gives the title bar the strip's height and centers the traffic lights in it.
        toolbar = NSToolbar()
        toolbarStyle = .unified
    }

    override var canBecomeKey: Bool { true }

    // Before the page: Escape in a focused page closes the window, as in Peek, unless it ends a text composition.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
           shouldCloseOnEscape?() == true {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }
}

/// Holds the Little window's chrome view over the page. The chrome is transparent and covers the window, so
/// only the places it reports as interactive (the strip, the command bar, a menu) take the pointer.
@MainActor
final class LittleChromeHost: NSView {
    let zones = ChromeInteractiveZoneStore()

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard zones.isInteractive(convert(point, from: unsafe superview), in: bounds, isFlipped: isFlipped) else { return nil }
        return super.hitTest(point)
    }
}
