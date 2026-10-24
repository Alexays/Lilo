import AppKit

/// The views of Changes tabs, keyed by tab id. A view loads its diff when first shown and watches
/// the disk only while on screen.
@MainActor
final class ChangesHost {
    private var views: [UUID: ChangesView] = [:]
    private var terminalColors: TerminalTheme.Resolved?

    func view(for id: UUID) -> ChangesView? {
        views[id]
    }

    func ensureView(for tab: Tab) -> ChangesView? {
        if let view = views[tab.id] { return view }
        guard let cwd = tab.cwd else { return nil }
        let view = ChangesView(directory: cwd)
        views[tab.id] = view
        return view
    }

    /// Takes a view already showing a diff (a peek opened in a split) as the tab's.
    func adopt(_ view: ChangesView, for id: UUID) {
        views[id] = view
    }

    func useTerminalColors(_ colors: TerminalTheme.Resolved) {
        guard colors != terminalColors else { return }
        terminalColors = colors
        ChangesDiffView.palette = ChangesDiffView.Palette(colors)
        for view in views.values { view.applyPalette() }
    }

    func forget(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
    }

    func prune(keeping isAlive: (UUID) -> Bool) {
        for id in views.keys where !isAlive(id) { forget(id) }
    }
}
