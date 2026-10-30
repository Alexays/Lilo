import AppKit
import WebKit

extension MainWindowController {
    /// Opens a Little window on the Space links from other apps open in, with its profile: `url`, or a
    /// blank page with the address field focused. A page's new window gets its `opener`'s Space and store,
    /// and with WebKit's `configuration` WebKit loads it and keeps `window.opener`.
    @discardableResult
    func openLittleWindow(url: URL?, opener: LittleWindowController? = nil, configuration: WKWebViewConfiguration? = nil) -> LittleWindowController? {
        guard let spaceId = opener?.spaceId ?? externalLinkSpaceId, let space = context.spaceManager?.space(with: spaceId) else { return nil }
        let dataStore = opener?.dataStore
            ?? (spaceId == tabManager.currentSpaceId ? tabManager.dataStore : context.profileManager?.dataStore(for: space.profileId))
            ?? context.engineFactory.defaultDataStore()
        let engine = context.engineFactory.createTab(configuration: .init(
            dataStore: dataStore,
            tabId: nil,
            nativeConfiguration: configuration,
            profileId: space.profileId
        ))
        configureEngineIfNeeded(engine)
        let little = LittleWindowController(engine: engine, spaceId: spaceId, dataStore: dataStore, owner: self)
        littleWindows[engine.id] = little
        if let url, configuration == nil { engine.loadURL(url) }
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
