import AppKit

extension MainWindowController {
    private var whatsNewVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    @objc func showWhatsNew(_ sender: Any?) {
        if isShowingWhatsNew { focusChrome(); return }
        guard !whatsNewRequested else { return }
        pendingWhatsNewAutomatic = false
        presentPendingWhatsNew()
    }

    func requestAutomaticWhatsNew() {
        // A chrome reload replaces the dialog's DOM, so release its native focus ownership first.
        if isShowingWhatsNew || whatsNewRequested { dismissWhatsNew() }
        whatsNewUIReady = true
        // Help can queue a request before the deferred chrome has installed its listener.
        if pendingWhatsNewAutomatic != nil { presentPendingWhatsNew(); return }
        #if !DEBUG
        guard context.windows.windows.first === self,
              context.whatsNew.reserveAutomatic(version: whatsNewVersion, freshInstall: context.settingsStore.shouldShowOnboarding)
        else { return }
        pendingWhatsNewAutomatic = true
        presentPendingWhatsNew()
        #endif
    }

    func presentPendingWhatsNew() {
        guard whatsNewUIReady, let automatic = pendingWhatsNewAutomatic, let window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil, !whatsNewRequested else { return }
        pendingWhatsNewAutomatic = nil
        whatsNewRequested = true
        bridgeRouter.send(event: "openWhatsNew", data: ["version": whatsNewVersion, "automatic": automatic])
    }

    func acknowledgeWhatsNew(version: String) {
        guard whatsNewRequested, !isShowingWhatsNew, version == whatsNewVersion else { return }
        whatsNewReturnResponder = window?.firstResponder
        isShowingWhatsNew = true
        contentContainerView?.setAccessibilityHidden(true)
        focusChrome()
        context.whatsNew.acknowledge(version: version)
    }

    func dismissWhatsNew() {
        pendingWhatsNewAutomatic = nil
        whatsNewRequested = false
        guard isShowingWhatsNew else { return }
        isShowingWhatsNew = false
        contentContainerView?.setAccessibilityHidden(false)
        let previous = whatsNewReturnResponder
        whatsNewReturnResponder = nil
        if let view = previous as? NSView, view.window === window {
            if contains(responder: view) { window?.makeFirstResponder(view) } else { focusContent(view) }
        } else if let terminal = activeTerminalView {
            focusContent(terminal)
        } else if let engine = tabManager.activeEngineTab {
            focusContent(engine.view)
        } else {
            focusChrome()
        }
    }

    func windowDidEndSheet(_ notification: Notification) { presentPendingWhatsNew() }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        !isShowingWhatsNew || item.action == #selector(showWhatsNew(_:))
    }
}
