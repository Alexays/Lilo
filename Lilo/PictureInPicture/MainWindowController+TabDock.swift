import AppKit

// Sidebar pip dock: while the app is active, a backgrounded in-call tab docks scaled at the
// bottom of the sidebar instead of covering page content; when the app backgrounds or the
// sidebar collapses, it moves to the always-on-top floating panel so the call stays visible.
extension MainWindowController {

    func setupTabDock() {
        // Single zone-stream fanout: the debug hitbox overlay reads the same feed when present.
        chromeInteractiveZones.onZonesChanged = { [weak self] zones in
            self?.chromeInput.debugOverlay?.zones = zones
            self?.tabDock.zonesChanged(zones)
        }
        // Every undock path funnels here, so the chrome slot can never outlive the native view.
        tabDock.onDockCleared = { [weak self] in self?.setPipDockActive(false) }
        tabDock.onReturnToTab = { [weak self] engineId in
            if self?.documentPiP.openerId == engineId { self?.documentPiP.close() }
            self?.tabDock.undock()
            // The dock outlives space switches: its tab may live in another space.
            self?.switchToRecentTab(engineId)
        }
        tabDock.onDismiss = { [weak self] engineId in
            if self?.documentPiP.openerId == engineId { self?.documentPiP.close() }
            // The call keeps running detached; a PiP-able video may still surface it.
            self?.tabDock.undock()?.autoEnterPictureInPictureIfEligible()
        }
        tabDock.onSlotLost = { [weak self] engine in
            self?.floatingTabPanel.float(engine)
        }
        tabDock.onPictureInPictureSlotLost = { [weak self] in self?.documentPiP.float() }
        documentPiP.onReturnToTab = { [weak self] openerId in
            // Pressed over another app: the tab only shows once Lilo is in front.
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.switchToRecentTab(openerId)
        }
        documentPiP.onClosed = { [weak self] openerId, replaced in
            guard let self else { return }
            context.browserState.pictureInPictureOpenerIds.remove(openerId)
            // Kept in the window only to draw its PiP window: a background tab leaves it again.
            if !replaced, tabManager.activeOpenTabId != openerId, !context.browserState.displayedTabIds.contains(openerId),
               let engine = tabManager.engineTab(for: openerId), engine.view.superview === contentContainerView,
               !engine.shouldRetainForWebInspector, !engine.isTabShareSource, !engine.isAgentControlled {
                engine.view.removeFromSuperview()
            }
            // A replacement is placed right after, docked over this one's slot or floating.
            if !replaced, tabDock.pictureInPictureOpenerId == openerId { tabDock.undock() }
        }
    }

    /// Docks `engine` in the sidebar slot; the chrome mounts the slot on the bridge event and the
    /// zone stream then positions the native container.
    func dockInCallTab(_ engine: WKWebViewTab) {
        guard let contentView = window?.contentView, tabLayout.position.isVertical, context.settingsStore.dockCallsInSidebar else {
            floatingTabPanel.float(engine)
            return
        }
        setPipDockActive(true, title: engine.currentTitle ?? "")
        tabDock.sidebarWidth = sidebarWidth
        tabDock.sidebarOnRight = tabLayout.position == .right
        tabDock.dock(
            engine,
            logicalSize: contentContainerView.bounds.size,
            in: contentView,
            above: chromeWebView,
            chromeView: chromeWebView
        )
    }

    /// App resigned active or the window occluded: the dock is invisible there, so the call moves
    /// to the always-on-top panel (the reason that panel exists).
    func moveDockedCallToPanel() {
        // Leaving the app from a call tab: its page's PiP window keeps the call in view, as leaving its tab does.
        if documentPiP.webView == nil, context.settingsStore?.autoPictureInPicture == true, let engine = tabManager.activeEngineTab,
           engine.isInCall, !engine.isAgentControlled, !engine.shouldRetainForWebInspector {
            if engine.callControls.hasPictureInPictureAction {
                autoEnterDocumentPiP(engine)
            } else if !engine.isTabShareSource {
                // A call whose page has no PiP window (Meet's companion mode) floats whole, as when leaving its tab; a
                // shared tab keeps its full-size layout for the share instead.
                floatingTabPanel.float(engine)
            }
        }
        if tabDock.pictureInPictureOpenerId != nil { placeDocumentPiP() }
        guard tabDock.isDocking, let engine = tabDock.undock() else { return }
        setPipDockActive(false)
        floatingTabPanel.float(engine)
    }

    /// App became active again: a panel-hosted call comes home to the sidebar dock, unless the user
    /// put the panel on another screen, where it stays visible next to the window.
    func moveFloatingCallToDock() {
        // Back in the app on the call tab: an automatic PiP window gives the call back to its tab.
        if let activeId = tabManager.activeOpenTabId, documentPiP.openerId == activeId, documentPiP.wasAutoEntered {
            documentPiP.close()
        } else {
            placeDocumentPiP()
        }
        if awaitingDocumentPiP != nil, awaitingDocumentPiP === tabManager.activeEngineTab { awaitingDocumentPiP = nil }
        // Back in the app on the call tab it floated: the page comes home to the window.
        if let active = tabManager.activeEngineTab, floatingTabPanel.hostedEngineId == active.id {
            showContentView(for: active)
            return
        }
        // Nil until bootstrap: the launch window comes on screen, and foregrounds, before settings load.
        guard context.settingsStore?.dockCallsInSidebar == true,
              let engineId = floatingTabPanel.hostedEngineId,
              let engine = tabManager.engineTab(for: engineId),
              engine.isInCall, !engine.isTabShareSource,
              floatingTabPanel.panelScreen == nil || floatingTabPanel.panelScreen == window?.screen else { return }
        floatingTabPanel.dismiss(hosting: engineId)
        dockInCallTab(engine)
    }

    func setPipDockActive(_ active: Bool, title: String = "") {
        bridgeRouter.send(event: "pipDockChanged", data: active ? ["active": true, "title": title] : ["active": false])
    }
}
