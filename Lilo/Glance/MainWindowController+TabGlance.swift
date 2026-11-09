import AppKit

// Glance: hovering a pinned tab or a favorite shows its live page in a card beside the sidebar. The chrome draws the
// card and asks for the page; the tab's own view fills the card's page slot until the card goes.
extension MainWindowController {

    func setupTabGlance() {
        // The chrome holds the card while the pointer is on its page, and lets it go once the pointer leaves.
        tabGlance.onPointerInside = { [weak self] inside in
            self?.bridgeRouter.send(event: "tabGlancePointer", data: ["inside": inside])
        }
    }

    /// Only a tab whose view nothing else shows: the shown tab, a split pane, the call dock or a PiP page keep theirs.
    func showTabGlance(_ tabId: UUID) {
        guard tabId != tabManager.activeOpenTabId, !context.browserState.displayedTabIds.contains(tabId),
              tabDock.engineId != tabId, floatingTabPanel.hostedEngineId != tabId, documentPiP.openerId != tabId,
              let contentView = window?.contentView, let engine = tabManager.ensureLiveEngine(forTabId: tabId),
              unsafe tabGlance.engineId == tabId || engine.view.superview == nil
        else { return bridgeRouter.send(event: "tabGlanceEnded") }
        tabManager.keepWarmedTab(id: tabId)
        engine.applyPageBackgroundColor(currentContentSurfaceColor)
        tabGlance.show(engine, in: contentView, above: chromeWebView)
    }

    /// Gives the glanced tab its view back. `notify` closes the card when it did not ask for this itself.
    func endTabGlance(notify: Bool = false) {
        guard tabGlance.engineId != nil else { return }
        if tabGlance.end() { window?.makeFirstResponder(tabManager.activeEngineTab?.wkWebView) }
        if notify { bridgeRouter.send(event: "tabGlanceEnded") }
    }
}
