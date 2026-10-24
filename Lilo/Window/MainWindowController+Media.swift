import AppKit

/// A tab on the sidebar's media card.
/// A tab paused from it (`Tab.pausedFromCardAt`) stays there, ready to play again, until it plays or closes.
struct MediaTab {
    /// The page registered Media Session next or previous track handlers.
    var hasTrackControls = false
}

extension BrowserContext {
    /// Sends every window its media tabs when they changed, once per main-thread turn.
    func mediaActivityChanged() {
        guard !mediaActivityPending else { return }
        mediaActivityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mediaActivityPending = false
            var sent: [ObjectIdentifier: NSArray] = [:]
            for window in windows.windows {
                guard let router = window.bridgeRouter else { continue }
                let key = ObjectIdentifier(window)
                let tabs = window.mediaSummaries()
                let bridged = tabs as NSArray
                sent[key] = bridged
                guard sentMediaActivity[key]?.isEqual(bridged) != true else { continue }
                router.send(event: "mediaActivity", data: ["tabs": tabs])
            }
            sentMediaActivity = sent
        }
    }
}

extension MainWindowController {
    /// The media tabs this window may show: those of a private Space only while the window shows it.
    func mediaSummaries() -> [[String: Any]] {
        context.mediaTabs.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap { id, media -> [String: Any]? in
            guard let tab = tabManager.tab(for: id), !tab.isClosed,
                  let spaceId = context.browserState.owningSpaceId(forTab: id),
                  let space = context.spaceManager?.space(with: spaceId),
                  !space.isPrivate || spaceId == tabManager.currentSpaceId else { return nil }
            return [
                "id": id.uuidString,
                "spaceId": spaceId.uuidString,
                "title": tab.title,
                "faviconDataURL": tab.faviconDataURL ?? "",
                "playing": tab.isAudioPlaying,
                "muted": tab.isMuted,
                "hasTrackControls": media.hasTrackControls
            ]
        }
    }

    func mediaPlaybackChanged(_ engine: WKWebViewTab, isPlaying: Bool) {
        let id = engine.id
        if isPlaying {
            if context.mediaTabs[id] == nil { context.mediaTabs[id] = MediaTab() }
            Task { [weak self] in
                let hasTrackControls = await engine.hasMediaTrackControls()
                guard let self, context.mediaTabs[id] != nil else { return }
                context.mediaTabs[id]?.hasTrackControls = hasTrackControls
                context.mediaActivityChanged()
            }
        } else if tabManager.tab(for: id)?.pausedFromCardAt == nil {
            context.mediaTabs[id] = nil
        }
        context.mediaActivityChanged()
    }

    /// `action` is play, pause, nexttrack or previoustrack.
    func controlMedia(tabId: UUID, action: String) {
        guard context.mediaTabs[tabId] != nil, let engine = context.browserState.liveEngine(forTab: tabId) else { return }
        if action == "pause" { context.browserState.updateTab(id: tabId) { $0.pausedFromCardAt = Date() } }
        engine.controlMedia(action)
    }
}
