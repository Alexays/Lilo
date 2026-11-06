import AppKit
import OSLog

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
    nonisolated private static func tabArchiveURL(_ appSupportDirectory: String) -> URL {
        URL(fileURLWithPath: appSupportDirectory).appendingPathComponent("ArchivedTabs.json")
    }

    /// Serial, so the writes land in the order they were made.
    private static let tabArchiveQueue = DispatchQueue(label: "fr.arouillard.lilo.tab-archive", qos: .utility)

    /// One save per main-thread turn, however many tabs were archived in it; each window's chrome gets its Space's list then.
    func saveTabArchive() {
        guard !tabArchiveSavePending else { return }
        tabArchiveSavePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            writeTabArchive()
            // A chrome on no Space has no archived tabs to show.
            for window in windows.windows where window.tabManager.currentSpaceId != nil {
                window.sendArchivedTabs()
            }
        }
    }

    /// Writes the archive off the main thread, private Spaces left out, unless the disk already holds it; at quit,
    /// waits for the disk.
    func writeTabArchive() {
        if tabArchiveSavePending {
            tabArchiveSavePending = false
            let entries = tabArchive.entries.filter { spaceManager?.space(with: $0.spaceId)?.isPrivate == false }
            if entries != savedTabArchive {
                savedTabArchive = entries
                let url = Self.tabArchiveURL(appSupportDirectory)
                let logger = Self.logger
                Self.tabArchiveQueue.async {
                    do { try JSONEncoder().encode(entries).write(to: url, options: .atomic) } catch {
                        logger.error("tab archive save failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        if isTerminating { Self.tabArchiveQueue.sync {} }
    }

    /// The archive a previous run saved, read off the main thread while the databases open.
    nonisolated static func readTabArchive(appSupportDirectory: String) -> [TabArchive.Entry] {
        guard let data = try? Data(contentsOf: tabArchiveURL(appSupportDirectory)) else { return [] }
        do { return try JSONDecoder().decode([TabArchive.Entry].self, from: data) } catch {
            Logger(liloCategory: "Database").error("tab archive unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func restoreTabArchive(_ saved: [TabArchive.Entry]) {
        guard !saved.isEmpty else { return }
        savedTabArchive = saved
        let expiry = Date().addingTimeInterval(-TabArchive.maxAge)
        tabArchive.entries = saved.filter { $0.archivedAt > expiry } + tabArchive.entries
    }

    /// A Space opens anew at launch, on no tab with its pinned and bookmarked tabs back on their home page, when set to
    /// or after an absence longer than it keeps idle tabs.
    func startsFresh(_ space: Space) -> Bool {
        settingsStore?.emptyWindowOnLaunch == true
            || (space.archiveAfterHours > 0 && (launchAbsence ?? 0) > Double(space.archiveAfterHours) * 3600)
    }

    /// A tab playing sound, in a call or in Picture in Picture, holding unsaved input or driven by an
    /// agent: neither the idle sweep nor Clear takes it.
    func isBusy(_ tab: Tab, engine: WKWebViewTab?) -> Bool {
        tab.isAudioPlaying || tab.isMicrophoneActive || tab.isCameraActive || tab.isScreenSharing || tab.isInCall
            || tab.isAgentControlled || tab.hasUnsavedFormData || engine?.isInPictureInPicture == true
    }

    /// Runs `archiveIdleTabs` every few minutes while Lilo is active, the first pass right after launch: in the
    /// background the timer is suspended, and on return a pass already due runs a few seconds later.
    func startArchiveSweep() {
        guard archiveSweepTimer == nil, !ProcessInfo.isRunningUnderXCTest else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 300, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.archiveSweepLastPass = Date()
                self.archiveIdleTabs()
            }
        }
        timer.resume()
        archiveSweepTimer = timer
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.archiveSweepSuspended else { return }
                self.archiveSweepSuspended = true
                self.archiveSweepTimer?.suspend()
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.archiveSweepSuspended else { return }
                self.archiveSweepSuspended = false
                // Rescheduled first: resumed as is, a deadline missed while suspended fires at once, mid app switch.
                let sinceLastPass = self.archiveSweepLastPass.map { Date().timeIntervalSince($0) } ?? .infinity
                self.archiveSweepTimer?.schedule(deadline: .now() + max(5, 300 - sinceLastPass), repeating: 300, leeway: .seconds(60))
                self.archiveSweepTimer?.resume()
            }
        }
        if !NSApp.isActive {
            archiveSweepSuspended = true
            timer.suspend()
        }
    }

    /// Archives the top-level unpinned web tabs of the loaded Spaces left longer than their Space's
    /// delay, except one a window shows, a Space's active tab, and a busy one. Returns what it archived.
    @discardableResult
    func archiveIdleTabs(now: Date = Date()) -> [TabArchive.Entry] {
        guard let spaceManager, let commander = windows.activeWindow ?? windows.windows.first else { return [] }
        var archived: [TabArchive.Entry] = []
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
            guard let snapshot = browserState.space(id: space.id) else { continue }
            let activeTabId = snapshot.spaceTab.state.activeTabId
            let cutoff = now.addingTimeInterval(-Double(space.archiveAfterHours) * 3600)
            let host = browserState.liveHost(for: space.id)
            for (id, viewedAt) in snapshot.spaceTab.state.viewedAt where viewedAt < cutoff && id != activeTabId && !shown.contains(id) {
                guard let stored = snapshot.spaceTab.tab(id: id), stored.kind == .web, let url = stored.url else { continue }
                let tab = browserState.runtimeOverlay.applied(to: stored)
                guard !isBusy(tab, engine: host?.engine(for: id) ?? snapshot.engines[id]) else { continue }
                let entry = TabArchive.Entry(spaceId: space.id, url: url, title: tab.title)
                tabArchive.add(entry)
                archived.append(entry)
                if let window = windows.windows(showing: space.id).first {
                    window.closeTabStateFirst(id: id, undoable: false, askingPage: false)
                } else {
                    browserState.discardParkedEngines([id], spaceId: space.id) { discardEngine($0) }
                    _ = try? commander.applyBrowserCommand(.closeTab(spaceId: space.id, tabId: id))
                }
            }
        }
        return archived
    }
}
