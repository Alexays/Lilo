// Session restoration and tab persistence.

import AppKit
import GRDB
import os
import WebKit

// MARK: - Session Restoration

extension MainWindowController {
    final class StartupNonCriticalUICoordinator {
        private(set) var hasStartedNavigation = false
        private var pendingWork: [() -> Void] = []

        func enqueue(_ work: @escaping () -> Void) {
            guard !hasStartedNavigation else {
                work()
                return
            }
            pendingWork.append(work)
        }

        func markNavigationStarted() {
            guard !hasStartedNavigation else { return }
            hasStartedNavigation = true
            let work = pendingWork
            pendingWork.removeAll(keepingCapacity: false)
            work.forEach { $0() }
        }
    }

    func restoreSession() async {
        let wasUncleanShutdown = !context.settingsStore.sessionCleanShutdown
        // Arm the sentinel for this run; applicationWillTerminate re-sets it only on a clean quit, so a crash leaves it false.
        context.settingsStore.sessionCleanShutdown = false
        // Every path below returns early; the UI's own request may have arrived before the decision.
        defer {
            bridgeRouter.send(event: "onboardingState", data: [
                "show": context.settingsStore.shouldShowOnboarding, "step": context.settingsStore.onboardingStep,
                "usage": context.settingsStore.get("onboardingUsage") ?? "browse"
            ])
            if wasUncleanShutdown {
                bridgeRouter.send(event: "crashRecoveryDetected")
            }
        }

        do {
            let preferredProfileId = preferredProfileIdForRestore()

            guard let initialSpace = try await resolveInitialSpace(preferredProfileId: preferredProfileId) else {
                guard let preferredProfileId else {
                    createSessionFallbackTab()
                    finishSessionRestore(metric: "restoreSessionFallbackNewTab")
                    return
                }

                context.settingsStore.resolveOnboarding(freshInstall: true)
                try restoreSpaceContext(ensureHomeSpace(for: preferredProfileId))
                finishSessionRestore(appliedWindowChrome: true, deferNonCriticalUIUntilChromeNavigation: true)
                return
            }

            context.settingsStore.resolveOnboarding(freshInstall: false)
            if tabManager.currentSpaceId == initialSpace.id {
                settleLaunchSpace()
                finishSessionRestore(deferNonCriticalUIUntilChromeNavigation: true)
                return
            }

            try restoreSpaceContext(initialSpace)
            settleLaunchSpace()
            finishSessionRestore(appliedWindowChrome: true, deferNonCriticalUIUntilChromeNavigation: true)
        } catch {
            createSessionFallbackTab()
            finishSessionRestore(metric: "restoreSessionFallbackNewTab", deferNonCriticalUIUntilChromeNavigation: true)
        }
    }

    /// Opens the launch's Space on no tab when it starts fresh, then archives what went idle meanwhile, so the chrome's
    /// first paint already shows the Space without them.
    func settleLaunchSpace(now: Date = Date()) {
        guard let spaceId = tabManager.currentSpaceId, let space = context.spaceManager.space(with: spaceId) else { return }
        if context.startsFresh(space), var snapshot = context.browserState.space(id: spaceId) {
            snapshot.spaceTab.deactivate()
            context.browserState.storeSpace(id: spaceId, snapshot: snapshot)
            tabManager.activeTabId = nil
            clearContentViewIfNoActiveTab()
        }
        launchArchived = context.archiveIdleTabs(now: now).filter { $0.spaceId == spaceId }
    }

    /// Shows the space a window was opened on, then what it was opened for.
    func openOnSpace(_ spaceId: UUID, opening: Opening) {
        if let space = context.spaceManager.space(with: spaceId) ?? context.spaceManager.spaces.first {
            try? restoreSpaceContext(space)
        }
        finishSessionRestore(appliedWindowChrome: true, deferNonCriticalUIUntilChromeNavigation: true)
        switch opening {
        case .nothing: break
        case .newTab: newTab(nil)
        case let .urls(urls): urls.forEach { createTabStateFirst(url: $0) }
        case let .tab(tabId): reclaimDisplayedTab(tabId)
        }
    }

    /// Opens `tabId` in a new window on its space; this window shows the neighbouring tab instead.
    /// `droppedAt` is the screen point (top-left origin) a dragged tab was dropped at, the new window's top-left.
    @discardableResult
    func moveTabToNewWindow(_ tabId: UUID, droppedAt point: NSPoint? = nil) -> MainWindowController? {
        guard !context.settingsStore.singleWindow, let spaceId = tabManager.currentSpaceId, let index = tabManager.tabIndex(for: tabId) else { return nil }
        if tabManager.activeOpenTabId == tabId, let neighbour = tabManager.adjacentOpenTabId(around: index, excluding: tabId) {
            activateTabStateFirst(id: neighbour)
        }
        var frame: NSRect?
        if let point, let size = window?.frame.size, let screenHeight = NSScreen.screens.first?.frame.height {
            frame = NSRect(x: point.x - 40, y: screenHeight - point.y - size.height + 20, width: size.width, height: size.height)
        }
        return context.openWindow(on: spaceId, opening: .tab(tabId), frame: frame)
    }

    func preferredProfileIdForRestore() -> UUID? {
        context.profileManager.restoreLastActiveProfileId()
            ?? context.profileManager.defaultProfile?.id
            ?? context.profileManager.profiles.first?.id
    }

    func restoreSpaceContext(_ space: Space) throws {
        guard tabManager.currentSpaceId != space.id else { return }
        context.spaceManager?.activeSpaceId = space.id
        try activateProfileContext(for: space)
        StartupMetrics.markOnce("restoreProfileContextReady")
        switchToSpace(space.id, forSessionRestore: true)
    }

    func finishSessionRestore(
        metric: String = "restoreSessionActiveContextReady",
        appliedWindowChrome: Bool = false,
        deferNonCriticalUIUntilChromeNavigation: Bool = false
    ) {
        if tabManager.openTabs.isEmpty { createSessionFallbackTab() }
        if !appliedWindowChrome {
            if deferNonCriticalUIUntilChromeNavigation {
                startupNonCriticalUICoordinator.enqueue { [weak self] in
                    guard let self else { return }
                    self.applyWindowChromeColors(self.currentWindowBackgroundCSSColor())
                }
            } else {
                applyWindowChromeColors(currentWindowBackgroundCSSColor())
            }
        }
        didCompleteSessionRestore = true
        context.startArchiveSweep()
        scheduleHiddenSpacePreload()
        flushPendingExternalURLs()
        // The active tab's web view is built once the chrome has applied its state (initialStateApplied):
        // built earlier, its content process launches alongside the chrome's and delays the first paint.
        dispatchChromeInitialStateIfPossible()
        preconnectRestoredActiveTab()
        StartupMetrics.mark(metric)
    }

    /// Opens the restored active tab's connection (DNS, TCP, TLS) while its web view waits for the
    /// chrome. A bare web view on the tab's data store reaches the same network session, and needs no
    /// content process to do it.
    func preconnectRestoredActiveTab() {
        guard let id = tabManager.activeOpenTabId, tabManager.engineTab(for: id) == nil,
              let url = tabManager.tab(for: id)?.url, url.scheme == "https" || url.scheme == "http",
              let store = tabManager.dataStore else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store.backingStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let selector = NSSelectorFromString("_preconnectToServer:")
        guard webView.responds(to: selector) else { return }
        webView.perform(selector, with: url)
        StartupMetrics.markOnce("firstContentPreconnected")
    }

    /// Restores the extensions, then loads the active tab, so their blockers and content scripts apply to its first page.
    func restoreExtensionsThenActiveTab() {
        guard let extensions = profileContext?.extensions else { return activateRestoredActiveRuntimeIfNeeded() }
        Task {
            await extensions.restore()
            activateRestoredActiveRuntimeIfNeeded()
        }
    }

    func activateRestoredActiveRuntimeIfNeeded() {
        if let id = tabManager.activeOpenTabId, tabManager.engineTab(for: id) == nil {
            tabManager.activateTabRuntime(id: id)
        }
    }

    private func createSessionFallbackTab() {
        if tabManager.currentSpaceId != nil {
            createTabStateFirst(url: nil)
            return
        }

        guard let profileId = preferredProfileIdForRestore(),
              let space = try? ensureHomeSpace(for: profileId),
              (try? restoreSpaceContext(space)) != nil else {
            return
        }
        createTabStateFirst(url: nil)
    }

    /// Points the window at `space`'s profile: pins it in the cache and binds its stores, extension
    /// registry and data store. Throws, after telling the user, when the profile's database is unreadable.
    @discardableResult
    func activateProfileContext(for space: Space) throws -> ProfileContext {
        let profileContext: ProfileContext
        do {
            profileContext = try context.profileContexts.context(for: space.profileId)
        } catch {
            Self.logger.error("profile database unavailable for \(space.profileId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            context.notifyProfileDatabaseFailure(profileId: space.profileId, error: error)
            throw error
        }
        if self.profileContext?.profileId != space.profileId {
            // Every profile some window shows stays loaded.
            context.profileContexts.pinnedProfileIds = Set(
                context.windows.windows.compactMap { $0 === self ? nil : $0.profileContext?.profileId }
            ).union([space.profileId])
        }
        tabManager.profileId = space.profileId
        tabManager.dataStore = space.isPrivate
            ? context.profileManager?.ephemeralDataStore(for: space.id)
            : context.profileManager?.dataStore(for: space.profileId)
        guard self.profileContext !== profileContext else {
            if tabManager.windowAdapter?.spaceId != space.id { bindExtensionRegistry(profileContext.extensions, spaceId: space.id) }
            return profileContext
        }

        context.profileManager?.activateProfile(id: space.profileId)
        // The previous profile's extensions stop acting through this window; the spaces it showed stay their background windows.
        if let previous = self.profileContext?.extensions {
            if let focused = previous.delegate.windowAdapter, focused === tabManager.windowAdapter {
                previous.notifyWindowFocused(false)
                previous.delegate.windowAdapter = nil
            }
            if previous.delegate.windowController === self {
                previous.delegate.windowController = nil
                previous.delegate.tabManager = nil
            }
        }
        self.profileContext = profileContext
        context.downloadManager.setStore(profileContext.downloads)
        if profileContext.sessionPersistence == nil {
            profileContext.sessionPersistence = makeSessionPersistence(for: profileContext)
            // At launch the chrome paints first (restoreExtensionsThenActiveTab): restoring holds this thread its first frame needs.
            // A chrome that never paints still gets them a few seconds in.
            if didChromeVisualReady {
                Task { await profileContext.extensions.restore() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await profileContext.extensions.restore() } }
            }
        }
        // A profile whose favicons are not the last to fill the cache (bounded by FaviconStore.maxRows,
        // also the cache size, so another profile's warm may have evicted these) warms off the main
        // actor: the restored snapshot reads the hosts of its own tabs from the store synchronously.
        if context.lastFaviconWarmProfileId != space.profileId {
            let store = profileContext.favicons
            let profileId = space.profileId
            Task { [context] in
                let entries = (try? await Task.detached(priority: .utility) { try store.all() }.value) ?? []
                for entry in entries {
                    context.faviconService.warmIfAbsent(host: entry.host, dataURL: entry.dataURL, dominantColor: entry.dominantColor)
                }
                context.lastFaviconWarmProfileId = profileId
            }
        }
        bindExtensionRegistry(profileContext.extensions, spaceId: space.id)
        sendExtensionsChangedEvent()
        return profileContext
    }

    /// Saves the spaces of `profileContext`'s profile that any window displays; private spaces and
    /// spaces of other profiles are never saved here.
    private func makeSessionPersistence(for profileContext: ProfileContext) -> SessionPersistence {
        let profileId = profileContext.profileId
        return SessionPersistence(
            tabDBPool: profileContext.pool,
            displayedSpaceIds: { [weak context = self.context] in
                guard let context else { return [] }
                return context.windows.windows.compactMap { window in
                    guard let spaceId = window.tabManager.currentSpaceId,
                          let space = context.spaceManager.space(with: spaceId),
                          space.profileId == profileId, !space.isPrivate else { return nil }
                    return spaceId
                }
            },
            // The store owns the canonical durable state (updateTab writes content into the durable
            // tree), so return it directly instead of rebuilding the whole tree via importState.
            stateProvider: { [weak context = self.context] spaceId in
                context?.browserState.space(id: spaceId)?.spaceTab.state
            },
            dedupKeyProvider: { [weak context = self.context] spaceId in
                // Cheap key off the store's owned SpaceTab: durableRevision bumps on every durable mutation.
                guard let spaceTab = context?.browserState.space(id: spaceId)?.spaceTab else { return nil }
                return SessionPersistence.SaveDedupKey(
                    spaceId: spaceId,
                    structureToken: spaceTab.structureToken,
                    durableRevision: spaceTab.durableRevision
                )
            }
        )
    }

    func resolveInitialSpace(preferredProfileId: UUID?) async throws -> Space? {
        guard let spaceManager = context.spaceManager, let profileId = preferredProfileId else { return nil }

        if spaceManager.spaces.isEmpty { return nil }
        if !spaceManager.hasSpaces(for: profileId) { return spaceManager.spaces.first }

        if let preferredSpaceId = await restorePreferredSpaceId(for: profileId),
           let preferredSpace = spaceManager.space(with: preferredSpaceId) {
            return preferredSpace
        }

        return spaceManager.spaces(for: profileId).first ?? spaceManager.spaces.first
    }

    @discardableResult
    func ensureHomeSpace(for profileId: UUID) throws -> Space {
        guard let spaceManager = context.spaceManager else { preconditionFailure("SpaceManager must be configured before creating a Home space") }
        return try spaceManager.createHomeSpace(for: profileId)
    }

    func restorePreferredSpaceId(for profileId: UUID) async -> UUID? {
        let storedSpaceIds: [String: UUID]
        if let startupSpaceIds = restoredStartupSpaceIdsByProfile[profileId] {
            storedSpaceIds = startupSpaceIds
        } else {
            storedSpaceIds = await restoreStoredSpaceIds(for: profileId)
        }
        if let id = storedSpaceIds["lastActiveSpaceId"],
           let space = context.spaceManager?.space(with: id), space.profileId == profileId { return id }
        if let id = storedSpaceIds["lastPersistentSpaceId"],
           let space = context.spaceManager?.space(with: id), space.profileId == profileId, !space.isPrivate { return id }
        return nil
    }

    /// Drops the saved tab and interaction state of spaces that no longer exist. Only profiles that own
    /// a space are swept, so no database gets created. A profile's database opens off the main thread;
    /// its spaces are read back on it once open, and the delete queues on the writer behind every save
    /// made before, ahead of every save made after.
    func deleteOrphanedSpaceStates() {
        guard let spaceManager = context.spaceManager, let dbManager = context.dbManager else { return }
        let profileIds = Set(spaceManager.spaces.filter { !$0.isPrivate }.map(\.profileId))
        Task.detached(priority: .utility) {
            for profileId in profileIds {
                let pool: DatabasePool
                do { pool = try dbManager.pool(for: profileId) } catch {
                    Self.logger.error("orphaned space state sweep skipped a profile: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                await MainActor.run {
                    let spaceIds = Set(spaceManager.spaces(for: profileId).filter { !$0.isPrivate }.map(\.id))
                    let databasePath = pool.path
                    pool.asyncWrite({ db in
                        try SpaceTabStateStore.deleteAllOn(db: db, exceptSpaces: spaceIds)
                        try InteractionStateStore.deleteAllOn(db: db, databasePath: databasePath, exceptSpaces: spaceIds)
                    }, completion: loggingPersistenceFailure("spaceStates.orphanCleanup[\(profileId.uuidString)]"))
                }
            }
        }
    }

    func restoreStoredSpaceIds(for profileId: UUID) async -> [String: UUID] {
        guard let pool = try? context.poolReportingFailure(for: profileId) else { return [:] }
        return (try? await BrowserContext.StartupBackgroundWork.runBlocking {
            try BrowserContext.loadStoredSpaceIds(from: pool)
        }) ?? [:]
    }

    // MARK: - Tab Persistence

    /// The selection rows this process last wrote per profile, so a switch back to them skips the write.
    private static var savedSpaceSelectionByProfile: [UUID: [String: UUID]] = [:]

    /// Space switches are a hot gesture: the mirror restorePreferredSpaceId reads is updated
    /// first, then both rows land in one transaction on the writer queue, off the main actor.
    func saveSpaceSelection(_ space: Space) {
        guard let pool = try? context.poolReportingFailure(for: space.profileId) else { return }
        let keys = space.isPrivate ? ["lastActiveSpaceId"] : ["lastActiveSpaceId", "lastPersistentSpaceId"]
        for key in keys { restoredStartupSpaceIdsByProfile[space.profileId, default: [:]][key] = space.id }
        // Process-wide rather than the per-window mirror: another window may have written since.
        guard keys.contains(where: { Self.savedSpaceSelectionByProfile[space.profileId]?[$0] != space.id }) else { return }
        for key in keys { Self.savedSpaceSelectionByProfile[space.profileId, default: [:]][key] = space.id }
        let spaceId = space.id.uuidString
        pool.asyncWrite({ db in
            for key in keys {
                try db.execute(sql: "INSERT OR REPLACE INTO appState (key, value) VALUES (?, ?)", arguments: [key, spaceId])
            }
        }, completion: loggingPersistenceFailure("spaceSelection[\(spaceId)]"))
    }

    /// One-shot take of the boot preload. Cleared on FIRST call regardless of match, so a later
    /// re-restore of the same space (hidden-space eviction, space switch) can never see stale
    /// boot-time data.
    func takePreloadedSpaceRestoreState(matching space: Space) -> PreloadedSpaceRestoreState? {
        defer { preloadedSpaceRestoreState = nil }
        guard let preloaded = preloadedSpaceRestoreState,
              preloaded.profileId == space.profileId,
              preloaded.spaceId == space.id else { return nil }
        return preloaded
    }

    /// Once launch settles, decodes the active profile's hidden spaces (tab tree, repair, archived
    /// interaction blobs) off the main actor into the snapshot cache, so the first switch into each
    /// is a cache hit. A space the cache gained meanwhile keeps its own snapshot.
    func scheduleHiddenSpacePreload() {
        guard let profileId = profileContext?.profileId,
              context.hiddenSpacePreloadProfileIds.insert(profileId).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let pool = try? context.dbManager?.pool(for: profileId) else { return }
            let spaceIds = context.spaceManager.spaces(for: profileId)
                .filter { !$0.isPrivate && context.browserState.space(id: $0.id) == nil }
                .map(\.id)
            guard !spaceIds.isEmpty else { return }
            let loaded = await Task.detached(priority: .background) {
                spaceIds.compactMap { spaceId -> (spaceId: UUID, generation: UInt64, state: SpaceTabState, interactionStates: [UUID: Data])? in
                    let generation = SpaceTabStateStore.writeGenerations.withLock { $0[spaceId] ?? 0 }
                    // A missing or unreadable row is left to the synchronous path, the one that quarantines.
                    guard let state = try? SpaceTabStateStore(dbPool: pool).load(spaceId: spaceId) else { return nil }
                    let interactionStates = (try? InteractionStateStore(dbPool: pool).load(spaceId: spaceId)) ?? [:]
                    return (spaceId, generation, state, interactionStates)
                }
            }.value
            for entry in loaded {
                guard context.browserState.space(id: entry.spaceId) == nil,
                      let space = context.spaceManager.space(with: entry.spaceId), space.profileId == profileId,
                      SpaceTabStateStore.writeGenerations.withLock({ $0[entry.spaceId] ?? 0 }) == entry.generation else { continue }
                context.browserState.storeSpace(
                    id: space.id,
                    snapshot: restoredSpaceSnapshot(for: space, state: entry.state, persistedInteractionStates: entry.interactionStates)
                )
                // One space per main-actor turn keeps a large session from blocking input.
                await Task.yield()
            }
        }
    }

    func restoredSpaceSnapshot(for space: Space) -> BrowserStateStore.SpaceSnapshot {
        // Take the boot preload even on a cache hit so it can never linger past the
        // first restore attempt (one-shot intent; a lingering value only wastes memory).
        let preloaded = takePreloadedSpaceRestoreState(matching: space)
        if let cached = context.browserState.space(id: space.id) {
            return cached
        }

        let state = preloaded?.tabState ?? loadedOrQuarantinedSpaceTabState(for: space)
        return restoredSpaceSnapshot(
            for: space,
            state: state,
            persistedInteractionStates: preloaded?.interactionStates ?? loadPersistedInteractionStates(for: space)
        )
    }

    /// Builds a space's snapshot from its decoded tab tree and archived interaction-state blobs.
    private func restoredSpaceSnapshot(
        for space: Space,
        state: SpaceTabState,
        persistedInteractionStates: [UUID: Data]
    ) -> BrowserStateStore.SpaceSnapshot {
        let projection = state.projectedSidebar(spaceId: space.id)
        // Sanitize at ingest: disk state is the only entry point for malformed urls/titles, so
        // every snapshot in the store is trusted and activation never re-sanitizes.
        var restoredTabs = sanitizeTabs(projection.tabs, spaceId: space.id)
        // No database before setup (and in tests): rehydrate from the in-memory cache only.
        let faviconStore = (try? context.dbManager?.pool(for: space.profileId)).map { FaviconStore(dbPool: $0) }
        context.faviconService.rehydrateRestoredTabs(&restoredTabs, store: faviconStore)
        let activeTabId = restorableActiveTabId(
            preferred: space.activeTabId ?? state.activeTabId,
            in: restoredTabs
        )
        // A Space starting fresh reopens its pinned and bookmarked tabs on their home page, not where they were left.
        let startsFresh = context.startsFresh(space)
        let restorableStateIds = Set(restoredTabs.lazy.filter { !startsFresh || !($0.isPinned || $0.isBookmarked) }.map(\.id))
        let interactionStates: [UUID: Any] = persistedInteractionStates
            .filter { restorableStateIds.contains($0.key) }
            .mapValues { ArchivedInteractionState(data: $0) }
        return BrowserStateStore.SpaceSnapshot(
            spaceTab: SpaceTab(
                spaceId: space.id,
                state: SpaceTabStateImporter.importState(
                    activeTabId: activeTabId,
                    activationHistory: state.activationHistory,
                    viewedAt: state.viewedAt,
                    tabs: restoredTabs,
                    folders: projection.folders,
                    treeItems: projection.treeItems,
                    spaceId: space.id
                )
            ),
            engines: [:],
            interactionStates: interactionStates,
            lastAccessedAt: Date()
        )
    }

    /// Interaction states captured when their space was left, written once switching settles: a
    /// burst of switches archives and writes each space once instead of on every switch.
    private static var pendingInteractionStates: [UUID: [UUID: Any]] = [:]
    private static var pendingInteractionStatesFlush: Task<Void, Never>?
    /// Crashes and kills usually follow the user leaving the app: held captures are written then.
    /// Registered only while captures are held.
    private static var pendingInteractionStatesResignObserver: NSObjectProtocol?

    /// Persists the live space's interaction states (never a private one); `debounced` delays the write, any other call flushes held captures first.
    /// Only the getter needs main: the snapshot holds no web-view reference, so archiving and the write run off it (blocking if `synchronous`).
    func persistInteractionStates(forSpace spaceId: UUID, synchronous: Bool = false, debounced: Bool = false) {
        if !debounced { Self.flushPendingInteractionStates(context: context, synchronous: synchronous) }
        guard tabManager.currentSpaceId == spaceId,
              let space = context.spaceManager?.space(with: spaceId), !space.isPrivate,
              let pool = try? context.poolReportingFailure(for: space.profileId) else { return }

        var states: [UUID: Any] = [:]
        if let activeId = tabManager.activeOpenTabId,
           let engine = tabManager.engineTab(for: activeId),
           let state = engine.interactionState {
            states[activeId] = state
        }
        for (tabId, state) in tabManager.engineHost.recentSavedInteractionStates(
            limit: Self.maxPersistedInteractionStatesPerSpace
        ) where states[tabId] == nil {
            states[tabId] = state
        }
        guard !states.isEmpty else { return }

        guard debounced else {
            Self.writeInteractionStates(states, spaceId: spaceId, pool: pool, synchronous: synchronous)
            return
        }
        Self.pendingInteractionStates[spaceId] = states
        // Registered again on each call so the flush always runs through the latest context.
        if let observer = Self.pendingInteractionStatesResignObserver { NotificationCenter.default.removeObserver(observer) }
        Self.pendingInteractionStatesResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak context] _ in
            MainActor.assumeIsolated {
                guard let context else { return }
                MainWindowController.flushPendingInteractionStates(context: context, synchronous: false)
            }
        }
        Self.pendingInteractionStatesFlush?.cancel()
        Self.pendingInteractionStatesFlush = Task { [context] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            Self.flushPendingInteractionStates(context: context, synchronous: false)
        }
    }

    /// Writes every held capture to its space's current profile; deleted or private spaces drop theirs.
    private static func flushPendingInteractionStates(context: BrowserContext, synchronous: Bool) {
        pendingInteractionStatesFlush?.cancel()
        pendingInteractionStatesFlush = nil
        if let observer = pendingInteractionStatesResignObserver {
            NotificationCenter.default.removeObserver(observer)
            pendingInteractionStatesResignObserver = nil
        }
        let pending = pendingInteractionStates
        pendingInteractionStates = [:]
        for (spaceId, states) in pending {
            guard let space = context.spaceManager?.space(with: spaceId), !space.isPrivate,
                  let pool = try? context.poolReportingFailure(for: space.profileId) else { continue }
            writeInteractionStates(states, spaceId: spaceId, pool: pool, synchronous: synchronous)
        }
    }

    private static func writeInteractionStates(_ states: [UUID: Any], spaceId: UUID, pool: DatabasePool, synchronous: Bool) {
        // Safe to hand across the actor hop below: see persistInteractionStates.
        nonisolated(unsafe) let capturedStates = states
        let databasePath = pool.path
        if synchronous {
            loggingPersistenceError("interactionStates.\(spaceId.uuidString)") {
                // Don't wipe previously-persisted rows when archiving happened to yield nothing.
                let entries = InteractionStateCodec.encodeAll(capturedStates, spaceId: spaceId)
                guard !entries.isEmpty else { return }
                try InteractionStateStore(dbPool: pool).replace(spaceId: spaceId, entries: entries)
            }
        } else {
            pool.asyncWrite({ db in
                let entries = InteractionStateCodec.encodeAll(capturedStates, spaceId: spaceId)
                guard !entries.isEmpty else { return }
                try InteractionStateStore.writeReplaceOn(db: db, databasePath: databasePath, spaceId: spaceId, entries: entries)
            }, completion: loggingPersistenceFailure("interactionStates.\(spaceId.uuidString)"))
        }
    }

    /// The persisted (still archived) interaction-state blobs for a space.
    func loadPersistedInteractionStates(for space: Space) -> [UUID: Data] {
        guard !space.isPrivate,
              let pool = try? context.poolReportingFailure(for: space.profileId),
              let raw = try? InteractionStateStore(dbPool: pool).load(spaceId: space.id) else { return [:] }
        return raw
    }

    /// Restore path entry point: a readable row (or none) restores normally; an unreadable row is
    /// quarantined and the space starts empty, so the next save can never overwrite the bad blob.
    /// A database failure (pool open, read) also degrades to empty, but is surfaced per profile.
    private func loadedOrQuarantinedSpaceTabState(for space: Space) -> SpaceTabState {
        do {
            return try restoredSpaceTabState(for: space)
        } catch let error as SpaceTabStateStoreError {
            Self.logger.error("space tab state unreadable for \(space.id.uuidString, privacy: .public), quarantining: \(String(describing: error), privacy: .public)")
            loggingPersistenceError("spaceTabStates.quarantine[\(space.id.uuidString)]") {
                let pool = try context.dbManager.pool(for: space.profileId)
                try SpaceTabStateStore(dbPool: pool).quarantine(spaceId: space.id)
            }
            bridgeRouter.send(event: "sessionRestoreDegraded", data: ["spaceName": space.name])
        } catch {
            context.notifyProfileDatabaseFailure(profileId: space.profileId, error: error)
        }
        return SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
    }

    private func restoredSpaceTabState(for space: Space) throws -> SpaceTabState {
        if let sessionPersistence = context.profileContexts.existingContext(for: space.profileId)?.sessionPersistence {
            return try sessionPersistence.restoreSpaceTabState(forSpace: space.id)
        }

        let tabPool = try context.dbManager.pool(for: space.profileId)
        return try SpaceTabStateStore(dbPool: tabPool).load(spaceId: space.id)
            ?? SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
    }

    func sanitizeTabs(_ tabs: [Tab], spaceId: UUID) -> [Tab] {
        tabs.compactMap { tab in
            let normalizedURLString = tab.url?.absoluteString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedURL = normalizedURLString.flatMap { urlString in
                urlString.isEmpty ? nil : URL(string: urlString)
            }
            let normalizedTitle = tab.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = normalizedTitle.isEmpty
                ? Tab.fallbackTitle(for: normalizedURL)
                : normalizedTitle

            if normalizedURL == nil,
               tab.kind == .web,
               resolvedTitle != Tab.placeholderTitle,
               !tab.isPinned,
               !tab.isBookmarked,
               !tab.isClosed {
                return nil
            }

            var sanitizedTab = tab
            sanitizedTab.spaceId = spaceId
            sanitizedTab.url = normalizedURL
            sanitizedTab.title = resolvedTitle
            return sanitizedTab
        }
    }

    func restorableActiveTabId(preferred preferredTabId: UUID?, in tabs: [Tab]) -> UUID? {
        preferredTabId.flatMap { id in tabs.contains(where: { $0.id == id && !$0.isClosed }) ? id : nil }
            ?? tabs.first(where: { !$0.isClosed })?.id
    }

    func clearContentViewIfNoActiveTab() {
        guard tabManager.activeTab == nil else { return }
        contentContainerView.subviews.forEach { $0.removeFromSuperview() }
        updateDisplayedTabs([])
    }

    func captureSpaceTabState(for space: Space) throws -> SpaceTabState {
        if tabManager.currentSpaceId == space.id {
            return browserSnapshot(for: space.id).spaceTab.state
        }
        // A space no window shows can hold changes not saved yet: its state in memory is the latest.
        if let snapshot = context.browserState.space(id: space.id) {
            return SpaceTabStateRepair.repaired(snapshot.spaceTab.state)
        }

        var state = try restoredSpaceTabState(for: space)
        if let activeTabId = space.activeTabId {
            state.activeTabId = activeTabId
        }
        return SpaceTabStateRepair.repaired(state)
    }
}
