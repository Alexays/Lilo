import AppKit

extension BrowserContext {
    /// Sends every window its media tabs when they changed, once per main-thread turn.
    func mediaActivityChanged() {
        guard !mediaActivityPending else { return }
        mediaActivityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mediaActivityPending = false
            var sent: [ObjectIdentifier: NSDictionary] = [:]
            for window in windows.windows {
                guard let router = window.bridgeRouter else { continue }
                let key = ObjectIdentifier(window)
                let data: [String: Any] = ["tabs": window.mediaSummaries(), "calls": window.callSummaries()]
                let bridged = data as NSDictionary
                sent[key] = bridged
                guard sentMediaActivity[key]?.isEqual(bridged) != true else { continue }
                router.send(event: "mediaActivity", data: data)
            }
            sentMediaActivity = sent
        }
    }
}

extension MainWindowController {
    /// The tabs of `ids` this window may show, sorted: those of a private Space only while the window shows it.
    private func shownTabs(_ ids: some Sequence<UUID>) -> [(tab: Tab, spaceId: UUID)] {
        ids.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let tab = tabManager.tab(for: id), !tab.isClosed,
                  let spaceId = context.browserState.owningSpaceId(forTab: id),
                  let space = context.spaceManager?.space(with: spaceId),
                  !space.isPrivate || spaceId == tabManager.currentSpaceId else { return nil }
            return (tab, spaceId)
        }
    }

    func mediaSummaries() -> [[String: Any]] {
        shownTabs(context.mediaTabIds).map { tab, spaceId in
            [
                "id": tab.id.uuidString,
                "spaceId": spaceId.uuidString,
                "title": tab.title,
                "faviconDataURL": tab.faviconDataURL ?? "",
                "playing": tab.isAudioPlaying,
                "muted": tab.isMuted,
                "hasTrackControls": context.browserState.liveEngine(forTab: tab.id)?.callControls.hasTrackControls ?? false
            ]
        }
    }

    /// The calls this window may show, with what their call card toggles. The page's own Media Session state wins
    /// where it gave one; WebKit's capture state covers a page that gave none, or a toggle made past the page.
    func callSummaries() -> [[String: Any]] {
        shownTabs(context.callTabIds).compactMap { tab, spaceId in
            guard let engine = context.browserState.liveEngine(forTab: tab.id) else { return nil }
            let controls = engine.callControls
            return [
                "id": tab.id.uuidString,
                "spaceId": spaceId.uuidString,
                "title": tab.title,
                "faviconDataURL": tab.faviconDataURL ?? "",
                "hasMicrophone": tab.isMicrophoneActive || controls.actions.contains("togglemicrophone"),
                "microphoneMuted": tab.isMicrophoneMuted || controls.microphoneActive == false || !tab.isMicrophoneActive,
                "hasCamera": tab.isCameraActive || controls.actions.contains("togglecamera"),
                "cameraOff": controls.cameraActive == false || !tab.isCameraActive || engine.wkWebView.cameraCaptureState == .muted,
                "muted": tab.isMuted,
                "canHangUp": controls.actions.contains("hangup")
            ]
        }
    }

    /// The call ⇧⌘M and the sidebar's call card act on.
    var shownCallTab: Tab? { shownTabs(context.callTabIds).first?.tab }

    func mediaPlaybackChanged(_ engine: WKWebViewTab, isPlaying: Bool) {
        let id = engine.id
        if isPlaying {
            context.mediaTabIds.insert(id)
        } else if tabManager.tab(for: id)?.pausedFromCardAt == nil {
            context.mediaTabIds.remove(id)
        }
        context.mediaActivityChanged()
    }

    /// `action` is play, pause, nexttrack or previoustrack.
    func controlMedia(tabId: UUID, action: String) {
        guard context.mediaTabIds.contains(tabId), let engine = context.browserState.liveEngine(forTab: tabId) else { return }
        if action == "pause" { context.browserState.updateTab(id: tabId) { $0.pausedFromCardAt = Date() } }
        engine.controlMedia(action)
    }

    /// `action` is togglemicrophone, togglecamera or hangup. The page's own handler goes first; without one, the
    /// toggles mute WebKit's capture, and the page keeps its tracks but sends silence and black frames.
    /// Turning one back on clears both sides, as either may have muted it (the sidebar's tab button mutes WebKit's).
    func controlCall(tabId: UUID, action: String) {
        guard context.callTabIds.contains(tabId), let tab = tabManager.tab(for: tabId),
              let engine = context.browserState.liveEngine(forTab: tabId) else { return }
        let controls = engine.callControls
        let handled = controls.actions.contains(action)
        switch action {
        case "togglemicrophone":
            let pageMuted = controls.microphoneActive == false
            if tab.isMicrophoneMuted || pageMuted {
                if tab.isMicrophoneMuted { engine.setMicrophoneMuted(false) }
                if pageMuted && handled { engine.controlMedia(action) }
            } else if handled {
                engine.controlMedia(action)
            } else if tab.isMicrophoneActive {
                engine.setMicrophoneMuted(true)
            }
        case "togglecamera":
            // Muting the camera changes no capture usage the tab records, so the card is told here.
            let setCamera = { [weak self] (muted: Bool) in engine.setCameraMuted(muted) { self?.context.mediaActivityChanged() } }
            let engineOff = engine.wkWebView.cameraCaptureState == .muted
            let pageOff = controls.cameraActive == false || !tab.isCameraActive
            if engineOff || pageOff {
                if engineOff { setCamera(false) }
                if pageOff && handled { engine.controlMedia(action) }
            } else if handled {
                engine.controlMedia(action)
            } else {
                setCamera(true)
            }
        case "hangup" where handled:
            engine.controlMedia(action)
        default:
            break
        }
    }

    func callUsageChanged(tabId: UUID, usage: WKWebViewTab.WebPermissionUsageState) {
        let inCall = usage.usesMicrophone || usage.usesCamera
        guard inCall != context.callTabIds.contains(tabId) else { return }
        if inCall { context.callTabIds.insert(tabId) } else { context.callTabIds.remove(tabId) }
        context.mediaActivityChanged()
    }
}
