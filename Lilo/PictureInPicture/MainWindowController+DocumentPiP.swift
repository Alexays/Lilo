import AppKit

extension MainWindowController {
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
