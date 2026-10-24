import AppKit

extension MainWindowController {
    /// Opens a Little window on this window's Space and its profile: `url`, or a blank page with the
    /// address field focused.
    @discardableResult
    func openLittleWindow(url: URL?) -> LittleWindowController? {
        guard let spaceId = tabManager.currentSpaceId else { return nil }
        let dataStore = tabManager.dataStore ?? context.engineFactory.defaultDataStore()
        let engine = context.engineFactory.createTab(configuration: .init(
            dataStore: dataStore,
            tabId: nil,
            nativeConfiguration: nil,
            profileId: tabManager.profileId
        ))
        configureEngineIfNeeded(engine)
        let little = LittleWindowController(engine: engine, spaceId: spaceId, dataStore: dataStore, owner: self)
        littleWindows[engine.id] = little
        if let url { engine.loadURL(url) }
        little.show()
        return little
    }

    /// The Little window's page becomes the active tab of `spaceId`, in a window showing that Space,
    /// else the active window switched to it. The live page moves when the Space runs in the same
    /// data store; otherwise its URL reloads there.
    func moveLittleWindow(_ little: LittleWindowController, toSpace spaceId: UUID) {
        let target = context.windows.windows(showing: spaceId).first ?? context.windows.activeWindow ?? self
        if target.tabManager.currentSpaceId != spaceId { target.switchToSpace(spaceId) }
        // Out of the map first: the adopted engine's events must reach the tab, not the Little window.
        littleWindows[little.engine.id] = nil
        let engine = little.detachEngine()
        if target.tabManager.dataStore === little.dataStore {
            target.createTabStateFirst(url: nil, adopting: engine)
        } else {
            target.createTabStateFirst(url: engine.currentURL)
            DispatchQueue.main.async { engine.teardown() }
        }
        little.window.close()
        target.showWindow(nil)
        target.window?.makeKeyAndOrderFront(nil)
    }
}
