import Foundation
import PluginCore

/// Binds the `tabs:read` and `tabs:open` host APIs to the window on screen. A plugin sees id,
/// url and title only; a tab it opens loads in the background of the current space, so a plugin
/// never takes the user's focus.
@MainActor
struct PluginTabsAdapter {
    private weak var windows: WindowRegistry?
    private weak var browserState: BrowserStateStore?

    init(windows: WindowRegistry? = nil, browserState: BrowserStateStore? = nil) {
        self.windows = windows
        self.browserState = browserState
    }

    /// Open web tabs of the active window's current space, in sidebar order.
    func list() -> [PluginTab] {
        guard let spaceId = windows?.activeWindow?.tabManager.currentSpaceId,
              let tabs = browserState?.structuralProjection(forSpace: spaceId)?.tabs else { return [] }
        return tabs.filter { $0.kind == .web && !$0.isClosed }.map(Self.plugin)
    }

    func open(_ url: URL) -> PluginTab? {
        windows?.activeWindow?.createTabStateFirst(url: url, activate: false).map(Self.plugin)
    }

    static func plugin(_ tab: Tab) -> PluginTab {
        PluginTab(id: tab.id.uuidString, url: tab.url?.absoluteString ?? "", title: tab.title)
    }
}
