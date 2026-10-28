import Foundation

/// Tabs taken out of a Space's unpinned list by the idle sweep or Clear, oldest first, kept
/// `maxAge` and at most `maxPerSpace` per Space.
struct TabArchive {
    struct Entry: Sendable, Codable, Equatable {
        var id = UUID()
        let spaceId: UUID
        let url: URL
        let title: String
        var archivedAt = Date()
        /// Its place in the unpinned list, where undoing a Clear puts it back.
        var index: Int?
    }

    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxPerSpace = 200

    var entries: [Entry] = []

    mutating func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count(where: { $0.spaceId == entry.spaceId }) > Self.maxPerSpace,
           let oldest = entries.firstIndex(where: { $0.spaceId == entry.spaceId }) {
            entries.remove(at: oldest)
        }
    }

    mutating func remove(_ ids: Set<UUID>) -> [Entry] {
        let removed = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        return removed
    }
}

extension BrowserContext {
    private var tabArchiveURL: URL {
        URL(fileURLWithPath: appSupportDirectory).appendingPathComponent("ArchivedTabs.json")
    }

    /// Serial, so the writes land in the order they were made.
    private static let tabArchiveQueue = DispatchQueue(label: "fr.arouillard.lilo.tab-archive", qos: .utility)

    /// One save per main-thread turn, however many tabs were archived in it.
    func saveTabArchive() {
        guard !tabArchiveSavePending else { return }
        tabArchiveSavePending = true
        DispatchQueue.main.async { [weak self] in self?.writeTabArchive() }
    }

    /// Writes the archive off the main thread, private Spaces left out; at quit, waits for the disk.
    func writeTabArchive() {
        if tabArchiveSavePending {
            tabArchiveSavePending = false
            let entries = tabArchive.entries.filter { spaceManager?.space(with: $0.spaceId)?.isPrivate == false }
            let url = tabArchiveURL
            let logger = Self.logger
            Self.tabArchiveQueue.async {
                do { try JSONEncoder().encode(entries).write(to: url, options: .atomic) } catch {
                    logger.error("tab archive save failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if isTerminating { Self.tabArchiveQueue.sync {} }
    }

    func restoreTabArchive() {
        guard let data = try? Data(contentsOf: tabArchiveURL) else { return }
        let saved: [TabArchive.Entry]
        do { saved = try JSONDecoder().decode([TabArchive.Entry].self, from: data) } catch {
            Self.logger.error("tab archive unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let expiry = Date().addingTimeInterval(-TabArchive.maxAge)
        tabArchive.entries = saved.filter { $0.archivedAt > expiry } + tabArchive.entries
    }

    /// A tab playing sound, in a call or in Picture in Picture, holding unsaved input or driven by an
    /// agent: neither the idle sweep nor Clear takes it.
    func isBusy(_ tab: Tab, engine: WKWebViewTab?) -> Bool {
        tab.isAudioPlaying || tab.isMicrophoneActive || tab.isCameraActive || tab.isScreenSharing || tab.isInCall
            || tab.isAgentControlled || tab.hasUnsavedFormData || engine?.pip.isActive == true
    }

    /// Runs `archiveIdleTabs` every few minutes; the first pass right after launch.
    func startArchiveSweep() {
        guard archiveSweepTimer == nil, !ProcessInfo.isRunningUnderXCTest else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 300, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.archiveIdleTabs() }
        }
        timer.resume()
        archiveSweepTimer = timer
    }

    /// Archives the top-level unpinned web tabs of the loaded Spaces left longer than their Space's
    /// delay, except one a window shows, a Space's active tab, and a busy one.
    func archiveIdleTabs(now: Date = Date()) {
        guard let spaceManager, let commander = windows.activeWindow ?? windows.windows.first else { return }
        let expiry = now.addingTimeInterval(-TabArchive.maxAge)
        if let oldest = tabArchive.entries.first, oldest.archivedAt < expiry {
            tabArchive.entries.removeAll { $0.archivedAt < expiry }
        }
        var shown = browserState.displayedTabIds
        for window in windows.windows {
            for id in [window.tabManager.activeTabId, window.tabDock.engineId, window.floatingTabPanel.hostedEngineId, window.documentPiP.openerId] {
                if let id { shown.insert(id) }
            }
        }
        for space in spaceManager.spaces where space.archiveAfterHours > 0 {
            guard let snapshot = browserState.space(id: space.id),
                  let activeTabId = snapshot.spaceTab.state.activeTabId else { continue }
            let cutoff = now.addingTimeInterval(-Double(space.archiveAfterHours) * 3600)
            let host = browserState.liveHost(for: space.id)
            for (id, viewedAt) in snapshot.spaceTab.state.viewedAt where viewedAt < cutoff && id != activeTabId && !shown.contains(id) {
                guard let stored = snapshot.spaceTab.tab(id: id), stored.kind == .web, let url = stored.url else { continue }
                let tab = browserState.runtimeOverlay.applied(to: stored)
                guard !isBusy(tab, engine: host?.engine(for: id) ?? snapshot.engines[id]) else { continue }
                tabArchive.add(TabArchive.Entry(spaceId: space.id, url: url, title: tab.title))
                if let window = windows.windows(showing: space.id).first {
                    window.closeTabStateFirst(id: id, undoable: false, askingPage: false)
                } else {
                    browserState.discardParkedEngines([id], spaceId: space.id) { discardEngine($0) }
                    _ = try? commander.applyBrowserCommand(.closeTab(spaceId: space.id, tabId: id))
                }
            }
        }
    }
}
