import AppKit

extension MainWindowController {
    /// Hidden elements are cosmetic rules: they run with the content blocker.
    var hidesElements: Bool { context.settingsStore?.contentBlockerEnabled == true }

    /// View > Hide Element: picks an element of the focused page.
    @objc func hideElement(_ sender: Any?) {
        guard let engine = focusedEngineTab else { return }
        tabRequestsHideElement(engine)
    }

    /// The picked element stays hidden on every page of the tab's host, `www.` or not.
    func tabRequestsHideElement(_ tab: WKWebViewTab) {
        guard hidesElements, let url = tab.currentURL, ["http", "https"].contains(url.scheme), let host = url.host?.lowercased() else { return }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        tab.pickElementToHide { [weak self] selector in
            guard let selector else { return }
            self?.context.hideElement(selector, onHost: site)
        }
    }
}
