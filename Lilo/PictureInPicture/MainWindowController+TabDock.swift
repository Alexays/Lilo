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
            self?.tabDock.undock()
            // The dock outlives space switches: its tab may live in another space.
            self?.switchToRecentTab(engineId)
        }
        tabDock.onDismiss = { [weak self] _ in
            // The call keeps running detached; a PiP-able video may still surface it.
            self?.tabDock.undock()?.autoEnterPictureInPictureIfEligible()
        }
        tabDock.onSlotLost = { [weak self] engine in
            self?.floatingTabPanel.float(engine)
        }
    }

    /// Docks `engine` in the sidebar slot; the chrome mounts the slot on the bridge event and the
    /// zone stream then positions the native container.
    func dockInCallTab(_ engine: WKWebViewTab) {
        guard let contentView = window?.contentView, tabLayout.position.isVertical else {
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
        guard tabDock.isDocking, let engine = tabDock.undock() else { return }
        setPipDockActive(false)
        floatingTabPanel.float(engine)
    }

    /// App became active again: a panel-hosted call comes home to the sidebar dock, unless the user
    /// put the panel on another screen, where it stays visible next to the window.
    func moveFloatingCallToDock() {
        guard let engineId = floatingTabPanel.hostedEngineId,
              let engine = tabManager.engineTab(for: engineId),
              engine.hasActiveCapture, !engine.isTabShareSource,
              floatingTabPanel.panelScreen == nil || floatingTabPanel.panelScreen == window?.screen else { return }
        floatingTabPanel.dismiss(hosting: engineId)
        dockInCallTab(engine)
    }

    private func setPipDockActive(_ active: Bool, title: String = "") {
        bridgeRouter.send(event: "pipDockChanged", data: active ? ["active": true, "title": title] : ["active": false])
    }
}
