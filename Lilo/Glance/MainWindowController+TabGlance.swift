import AppKit

// Glance: hovering a pinned tab or a favorite shows its live page in a card beside the sidebar. The chrome draws the
// card and asks for the page; the tab's own view fills the card's page slot until the card goes.
extension MainWindowController {

    func setupTabGlance() {
        // The chrome holds the card while the pointer is on its page, and lets it go once the pointer leaves.
        tabGlance.onPointerInside = { [weak self] inside in
            self?.bridgeRouter.send(event: "tabGlancePointer", data: ["inside": inside])
        }
        tabGlance.onUsed = { [weak self] in self?.tabManager.keepGlancedTabAwake() }
        tabGlance.onDismiss = { [weak self] in self?.endTabGlance(notify: true) }
    }

    /// Only a tab whose view nothing else holds: the shown tab, a split pane, the call dock, a PiP page and a view kept
    /// in the window (inspected, shared, an agent's) keep theirs.
    func showTabGlance(_ tabId: UUID) {
        guard tabGlance.engineId != tabId else { return }
        endTabGlance()
        let viewIsFree = unsafe tabManager.engineTab(for: tabId)?.view.superview == nil
        guard viewIsFree, !context.browserState.displayedTabIds.contains(tabId),
              tabDock.engineId != tabId, floatingTabPanel.hostedEngineId != tabId, documentPiP.openerId != tabId,
              let contentView = window?.contentView, let engine = tabManager.beginGlance(ofTab: tabId)
        else { return bridgeRouter.send(event: "tabGlanceEnded") }
        engine.applyPageBackgroundColor(currentContentSurfaceColor)
        tabGlance.show(engine, in: contentView, above: chromeWebView)
    }

    /// Gives the glanced tab its view back. `notify` closes the card when it did not ask for this itself.
    func endTabGlance(notify: Bool = false) {
        guard tabGlance.engineId != nil else { return }
        if tabGlance.end() { window?.makeFirstResponder(tabManager.activeEngineTab?.wkWebView) }
        tabManager.endGlance()
        if notify { bridgeRouter.send(event: "tabGlanceEnded") }
    }
}
