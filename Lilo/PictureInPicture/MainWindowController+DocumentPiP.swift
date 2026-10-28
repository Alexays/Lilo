import AppKit
import OSLog
import WebKit

extension MainWindowController {
    static let documentPiPFallbackDelay: TimeInterval = 1.5
    private static let documentPiPLogger = Logger(liloCategory: "pip")

    /// Leaving a call tab whose page offers its own PiP window: asks the page for it, and shows the whole page in
    /// the dock or the panel instead when no window comes within `documentPiPFallbackDelay`.
    /// Whether the page of `webView` may open its PiP window now: with a user activation, or answering Lilo's
    /// automatic opening.
    static func prepareDocumentPiP(in context: BrowserContext, webView: WKWebView, size: NSSize, userActivated: Bool) -> Bool {
        if let (window, engine) = context.windows.windowAndEngine(for: webView) {
            return window.documentPiP.prepare(engine, size: size, userActivated: userActivated, automatic: window.awaitingDocumentPiP === engine)
        }
        // A call tab left by a space switch is parked before its page answers the automatic opening.
        guard let window = context.windows.windows.first(where: { $0.awaitingDocumentPiP?.wkWebView === webView }),
              let engine = window.awaitingDocumentPiP else { return false }
        return window.documentPiP.prepare(engine, size: size, userActivated: userActivated, automatic: true)
    }

    func autoEnterDocumentPiP(_ engine: WKWebViewTab) {
        awaitingDocumentPiP = engine
        engine.enterDocumentPictureInPicture()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.documentPiPFallbackDelay) { [weak self, weak engine] in
            guard let self, let engine, awaitingDocumentPiP === engine else { return }
            awaitingDocumentPiP = nil
            guard tabManager.activeOpenTabId != engine.id else { return }
            if !engine.isPrivateBrowsing { Self.documentPiPLogger.info("document pip fallback host=\(engine.currentURL?.host ?? "nil", privacy: .private)") }
            popOutWholePage(engine)
        }
    }

    /// Docks the Document PiP window in the sidebar while this window is in front and its page's tab is not
    /// shown, and floats it otherwise: over other apps, or beside the tab it belongs to. A panel the user put on
    /// another screen stays there.
    func placeDocumentPiP() {
        guard let webView = documentPiP.webView, let openerId = documentPiP.openerId else { return }
        let panelScreen = documentPiP.panelScreen
        if let contentView = window?.contentView, NSApp.isActive, window?.isVisible == true, tabLayout.position.isVertical,
           context.settingsStore?.dockCallsInSidebar == true, tabManager.activeOpenTabId != openerId,
           panelScreen == nil || panelScreen == window?.screen {
            documentPiP.hidePanel()
            tabDock.sidebarWidth = sidebarWidth
            tabDock.sidebarOnRight = tabLayout.position == .right
            // Docking replaces a docked tab, whose undock tears the chrome slot down: mount it after.
            tabDock.dockPictureInPicture(webView, openerId: openerId, in: contentView, above: chromeWebView, chromeView: chromeWebView)
            setPipDockActive(true, title: tabManager.engineTab(for: openerId)?.currentTitle ?? "")
        } else {
            if tabDock.pictureInPictureOpenerId == openerId { tabDock.undock() }
            documentPiP.float()
        }
    }
}
