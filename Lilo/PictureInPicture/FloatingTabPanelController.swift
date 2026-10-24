import AppKit
import Foundation
import WebKit

/// Hosts one tab's live web view in an always-on-top panel. WebKit ships no
/// `documentPictureInPicture`, so a call kept in view has to be the real page, moved into a panel,
/// rather than a DOM subtree rendered in a separate window.
@MainActor
final class FloatingTabPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var engineId: UUID?
    private var titleObservation: NSKeyValueObservation?

    var hostedEngineId: UUID? { engineId }
    var panelScreen: NSScreen? { panel?.screen }

    private static let defaultSize = NSSize(width: 480, height: 300)
    private static let screenMargin: CGFloat = 24

    /// Move `engine`'s view into the panel, titled with its page as long as it floats.
    func float(_ engine: WKWebViewTab) {
        if engineId != engine.id { dismiss() }
        engineId = engine.id

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.title = engine.currentTitle ?? ""
        titleObservation = engine.wkWebView.observe(\.title) { [weak panel] webView, _ in
            MainActor.assumeIsolated { panel?.title = webView.title ?? "" }
        }

        guard let contentView = panel.contentView else { return }
        let view = engine.view
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        view.isHidden = false
        if view.superview !== contentView { contentView.addSubview(view) }
        panel.orderFrontRegardless()
    }

    /// Close the panel if it hosts `id`, leaving the view detached for the window to re-adopt.
    func dismiss(hosting id: UUID) {
        guard engineId == id else { return }
        dismiss()
    }

    /// Teardown runs in `windowWillClose`, which `close()` posts synchronously, so closing by code and
    /// closing by the title bar button take the same path.
    func dismiss() {
        panel?.close()
    }

    private func makePanel() -> NSPanel {
        // Non-activating so clicking the call doesn't pull the whole browser forward, which is what
        // makes the panel usable on top of another app.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 320, height: 180)
        panel.delegate = self
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.defaultSize.width - Self.screenMargin,
                y: visible.minY + Self.screenMargin
            ))
        }
        panel.setFrameAutosaveName("LiloFloatingTab")
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel, closing === panel else { return }
        panel = nil
        engineId = nil
        titleObservation = nil
        // The view goes back to being an ordinary backgrounded tab: detached, re-adopted on select.
        closing.contentView?.subviews.forEach { $0.removeFromSuperview() }
    }
}
