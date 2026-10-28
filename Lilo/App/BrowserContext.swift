import AppKit
import GRDB
import OSLog
import ScreenCaptureKit

/// App-wide browser services. Windows present them; none of them belongs to a window.
@MainActor
final class BrowserContext {
    static let logger = Logger(liloCategory: "Database")

    struct StartupSnapshot: @unchecked Sendable {
        let profiles: [Profile]
        let spaces: [Space]
        let lastActiveProfileId: UUID?
        var storedSpaceIdsByProfile: [UUID: [String: UUID]]
        let windowBackgroundColor: String?
        /// Read before any window saves the table, so the windows to reopen are never overwritten first.
        var windows: [StoredWindow] = []
    }

    enum StartupBackgroundWork {
        static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try work())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private struct DatabaseBootstrap: Sendable {
        let dbManager: DatabaseManager
        let startupSnapshot: StartupSnapshot
    }

    let browserState: BrowserStateStore
    let engineFactory = WKEngineFactory()
    let downloadManager = DownloadManager()
    let faviconService = FaviconService()
    /// The profile whose favicon table last filled the shared cache; another profile's warm can evict its entries.
    var lastFaviconWarmProfileId: UUID?
    let terminalHost = TerminalHost()
    let changesHost = ChangesHost()
    /// Set by the first window: the terminal host is shared, so one observer serves every window.
    var terminalAppearanceObservation: NSKeyValueObservation?
    var terminalActivityPending = false
    /// The terminals last sent to each window, so an unchanged list costs no bridge message.
    var sentTerminalActivity: [ObjectIdentifier: NSArray] = [:]
    /// Tabs playing media, or paused from the sidebar's media card, for that card.
    /// A tab paused from it (`Tab.pausedFromCardAt`) stays there, ready to play again, until it plays or closes.
    var mediaTabIds: Set<UUID> = []
    /// Tabs capturing the microphone or camera, for the sidebar's call card.
    var callTabIds: Set<UUID> = []
    var mediaActivityPending = false
    /// The media and call tabs last sent to each window, so unchanged lists cost no bridge message.
    var sentMediaActivity: [ObjectIdentifier: NSDictionary] = [:]
    let powerKeeper = PowerKeeper()
    var recentlyClosed = RecentlyClosedStack() {
        didSet { saveClosedTerminals() }
    }
    var closedTerminalsSavePending = false
    var tabArchive = TabArchive() {
        didSet { saveTabArchive() }
    }
    var tabArchiveSavePending = false
    var archiveSweepTimer: DispatchSourceTimer?
    /// The closed terminals last handed to the disk, so a change that leaves them alone writes nothing.
    var savedClosedTerminals: [RecentlyClosedStack.Entry]?
    /// Profiles whose hidden spaces a window preloaded, so another window does not repeat it.
    var hiddenSpacePreloadProfileIds: Set<UUID> = []
    let profileContexts: ProfileContextCache
    let windows: WindowRegistry
    /// Created on first use: no folder can be unlocked before then, so nothing needs relocking.
    private(set) lazy var folderAutoLock = FolderAutoLock(context: self)
    /// One per app: the system device and display observers must not repeat per window. Created by the
    /// first window, after bootstrap; its state reaches every window's settings page.
    private(set) lazy var deviceSetupController: DeviceSetupController = {
        let controller = DeviceSetupController(settingsStore: settingsStore)
        controller.onStateChange = { [weak self, unowned controller] in
            guard let self else { return }
            let state = controller.bridgeState
            for window in windows.windows { window.bridgeRouter?.send(event: "deviceSetupLoaded", data: state) }
        }
        return controller
    }()
    lazy var agentControl = AgentControl(context: self)
    let appSupportDirectory: String
    private let makeProfileId: @MainActor () -> UUID

    // Set by bootstrap(), which every window awaits before reading them.
    private(set) var dbManager: DatabaseManager!
    private(set) var settingsStore: SettingsStore!
    private(set) var sitePermissionStore: SitePermissionStore!
    private(set) var profileManager: ProfileManager!
    private(set) var spaceManager: SpaceManager!
    private(set) var startupSnapshot: StartupSnapshot!
    /// Keeps the content blocker's rules current from remote filter lists (EasyList). See FilterListService.
    private(set) var filterListService: FilterListService?
    /// One degraded-database alert per subject (profile id or "settings") per launch.
    private var notifiedDegradedDatabaseSubjects: Set<String> = []
    private var bootstrapTask: Task<Void, Error>?

    init(
        browserState: BrowserStateStore = BrowserStateStore(),
        appSupportDirectory: String = BuildIdentity.appSupportDirectory,
        makeProfileId: @escaping @MainActor () -> UUID = UUID.init
    ) {
        self.browserState = browserState
        self.appSupportDirectory = appSupportDirectory
        self.makeProfileId = makeProfileId
        windows = WindowRegistry(browserState: browserState)
        let engineFactory = engineFactory
        weak var weakSelf: BrowserContext?
        profileContexts = ProfileContextCache { profileId in
            guard let dbManager = weakSelf?.dbManager else { throw BrowserContextError.notBootstrapped }
            let context = try ProfileContext(
                profileId: profileId, dbManager: dbManager, gapRouter: engineFactory.gapRouter,
                tabShare: (engineFactory.tabShareBridge, engineFactory.tabShareFrameSchemeHandler)
            )
            context.extensions.settingsStore = weakSelf?.settingsStore
            engineFactory.prepareExtensionRegistry(context.extensions)
            let blockerExtension = weakSelf?.blockerExtensionURL
            Task { await context.extensions.loadBlockerExtension(at: blockerExtension) }
            return context
        }
        weakSelf = self
        engineFactory.profileContexts = profileContexts
        engineFactory.downloadManager = downloadManager
        faviconService.storeForProfile = { [profileContexts] in profileContexts.existingContext(for: $0)?.favicons }
        installDownloadGapEventObservers()
        installTabGroupEventObserver()
        installTabShareRouting()
    }

    /// The bridge is shared by every window: each call goes to the window holding the page, never
    /// to whichever window registered last, which may be closed.
    private func installTabShareRouting() {
        let windows = windows
        let bridge = engineFactory.tabShareBridge
        bridge.pickerPresenter = { origin, requester in
            await windows.window(for: requester)?.presentTabSharePicker(origin: origin, requester: requester) ?? .cancel
        }
        bridge.sessionStarter = { tabId, requester in
            windows.window(for: requester)?.startTabShare(tabId: tabId, requester: requester)
        }
        bridge.sessionStopper = { token in
            windows.windows.forEach { $0.tabShareSessions.stop(token: token) }
        }
        let capture = engineFactory.captureHandler
        let screenPicker = ScreenContentPicker()
        capture.picker = { title, sources in
            let modes: SCContentSharingPickerMode = [
                sources.contains("screen") ? .singleDisplay : [],
                sources.contains("window") ? .singleWindow : []
            ]
            if sources.contains("tab"), let window = windows.activeWindow {
                switch await window.presentTabSharePicker(origin: title, requester: nil, allowsSystem: !modes.isEmpty) {
                case .tab(let tabId): return .tab(tabId)
                case .cancel: return nil
                case .system: break
                }
            }
            guard !modes.isEmpty, !Task.isCancelled else { return nil }
            return await screenPicker.pick(allowing: modes).map { .screen($0) }
        }
        bridge.streamOpener = { streamId, mediaSource, origin, requester in
            guard let grant = capture.redeem(streamId, mediaSource: mediaSource, origin: origin) else { return nil }
            let reply: [String: Any]?
            let window: MainWindowController?
            switch grant.source {
            case .tab(let tabId):
                window = windows.window(forTab: tabId)
                reply = window?.startTabShare(tabId: tabId, requester: requester)
            case .screen(let filter):
                let screen = ScreenCaptureStream(filter: filter)
                window = windows.window(for: requester)
                guard window != nil, (try? await screen.start()) != nil else { return nil }
                reply = window?.tabShareSessions.start(screen: screen, requester: requester)
            }
            if let token = reply?["token"] as? String { capture.captureStarted(token: token, grant: grant) }
            return reply
        }
        engineFactory.tabShareFrameSchemeHandler.frameProvider = { token, afterSeq, wantsKey, puller in
            for window in windows.windows {
                let result = window.tabShareSessions.frame(token: token, afterSeq: afterSeq, wantsKey: wantsKey, puller: puller)
                if case .gone = result { continue }
                return result
            }
            return .gone
        }
    }

    /// Opens the databases and loads settings, profiles and spaces. Idempotent: every caller awaits one run.
    func bootstrap() async throws {
        if let bootstrapTask { return try await bootstrapTask.value }
        let task = Task { try await performBootstrap() }
        bootstrapTask = task
        try await task.value
    }

    private func performBootstrap() async throws {
        let appSupportDirectory = appSupportDirectory
        let bootstrap = try await StartupBackgroundWork.runBlocking {
            try Self.makeDatabaseBootstrap(appSupportDirectory: appSupportDirectory)
        }
        dbManager = bootstrap.dbManager
        startupSnapshot = bootstrap.startupSnapshot
        settingsStore = SettingsStore(dbPool: dbManager.globalPool)
        engineFactory.setTrackingPrevention(settingsStore.preventCrossSiteTracking)
        engineFactory.microphoneBridge.isEnabled = { [weak self] in self?.settingsStore.fullBandMicrophone ?? false }
        if let loadError = settingsStore.initialLoadError {
            showDegradedDatabaseAlert(
                subject: "settings",
                message: "Lilo couldn't load its settings".localized,
                informative: "Default settings are in use for this session.".localized,
                error: loadError
            )
        }
        KeyboardShortcuts.load(from: settingsStore)
        terminalHost.powerKeeper = powerKeeper
        terminalHost.changesHost = changesHost
        if !ProcessInfo.isRunningUnderXCTest {
            powerKeeper.start(lidActions: { [weak self] in
                SystemLidActions(
                    freezeWebTabs: { [weak self] in self?.browserState.freezeAllEngines() ?? [] },
                    agentProcesses: { [weak self] in self?.agentControl.sessions.map(\.connection.peerPID).filter { $0 > 0 } ?? [] }
                )
            }, monitorSystem: true)
        }
        powerKeeper.apply(PowerKeeper.Settings(get: settingsStore.get))
        if settingsStore.get("agentControlEnabled") == "true" {
            agentControl.setEnabled(true)
            AgentClientConfig.repairMovedConfigs(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        powerKeeper.onChange = { [weak self] state in
            // Browser agents hold the Mac like quiet commands: the popover names them beside the terminals.
            let holding = (self?.agentControl.sessions ?? []).filter { state.working.contains($0.id) }
            let agents = Set(holding.map { AgentControl.displayName($0.clientName) }).sorted()
            for window in self?.windows.windows ?? [] {
                window.bridgeRouter?.send(event: "keepAwakeChanged", data: [
                    "keepsAwake": state.keepsAwake, "agents": agents,
                    "tabIds": state.working.map(\.uuidString),
                    "holdsLidClosed": state.holdsLidClosed, "helperStatus": state.helperStatus
                ])
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Approval happens in System Settings, while Lilo is in the background.
            MainActor.assumeIsolated {
                if self?.powerKeeper.state.helperStatus == "requiresApproval" { self?.powerKeeper.refreshHelperStatus() }
                self?.terminalHost.refreshGitStats()
            }
        }
        sitePermissionStore = SitePermissionStore(dbPool: dbManager.globalPool)
        profileManager = ProfileManager(dbManager: dbManager, engineFactory: engineFactory, makeProfileId: makeProfileId)
        try profileManager.loadProfiles(
            startupSnapshot.profiles,
            lastActiveProfileId: startupSnapshot.lastActiveProfileId
        )
        profileManager.delegate = self
        spaceManager = SpaceManager(dbPool: dbManager.globalPool)
        spaceManager.loadSpaces(startupSnapshot.spaces)
        spaceManager.delegate = self
        restoreTabArchive()
    }

    /// At launch, and when the blocker is turned on in a session that launched with it off (nothing
    /// was compiled and the list service never started then).
    func startContentBlocker() async {
        let enabled = settingsStore.contentBlockerEnabled
        // With a usable FilterListService cache the bundled list would be compiled only to be
        // replaced moments later by the cached external rules; the bundled compile is the
        // no-cache (first-run) fallback.
        if !enabled {
            engineFactory.applyBlockerChange(enabled: false)
        } else if !FilterListService.hasUsableCache {
            await engineFactory.rebuildBlocker(allowlist: settingsStore.blockerAllowlist)
        }
        // Upgrade the small bundled list to the full EasyList in the background (cache, then network).
        guard enabled, filterListService == nil else { return }
        let service = FilterListService(
            engineFactory: engineFactory,
            allowlistProvider: { [weak self] in self?.settingsStore.blockerAllowlist ?? BlockerAllowlist() }
        )
        service.listSelection = { [weak self] in self?.settingsStore.filterListSelection ?? .init() }
        service.onBlockerExtensionChanged = { [weak self] in self?.reloadBlockerExtension() }
        filterListService = service
        service.start()
    }

    /// The content blocker's built-in extension, while the blocker runs and once written.
    var blockerExtensionURL: URL? {
        let url = FilterListService.blockerExtensionURL
        guard settingsStore.contentBlockerEnabled,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        return url
    }

    /// Loads the built-in extension into every profile anew, or removes it while the blocker is off.
    func reloadBlockerExtension() {
        let url = blockerExtensionURL
        for context in profileContexts.allContexts {
            Task { await context.extensions.loadBlockerExtension(at: url) }
        }
    }

    /// The content blocker's state for the settings page.
    var contentBlockerStatus: [String: Any] {
        let status = filterListService?.status ?? .init()
        var state: [String: Any] = ["updating": filterListService?.isRefreshing ?? false, "lists": status.lists]
        if let updated = status.updated { state["updated"] = updated.timeIntervalSince1970 }
        return state
    }

    /// Fetches and converts the lists now; nothing while the blocker is off.
    func updateFilterLists() async {
        await filterListService?.refreshNow()
    }

    private(set) lazy var sessionPersistenceCoordinator = SessionPersistenceCoordinator(
        dbManager: dbManager,
        liveStore: { [weak self] in self?.profileContexts.existingContext(for: $0)?.sessionPersistence }
    )

    /// Writes every persistent space's tab tree into its own profile's database; private spaces leave nothing.
    func saveSpaceStatesBeforeQuit() {
        guard let spaceManager else { return }
        var statesByProfile: [UUID: [(spaceId: UUID, state: SpaceTabState)]] = [:]
        for entry in browserState.persistableSpaceTabStates() {
            guard let space = spaceManager.space(with: entry.spaceId), !space.isPrivate else { continue }
            spaceManager.setActiveTab(entry.state.activeTabId, forSpace: space.id)
            statesByProfile[space.profileId, default: []].append(entry)
        }
        for (profileId, states) in statesByProfile {
            do {
                try sessionPersistenceCoordinator.persistSpaceTabStates(states, inProfile: profileId)
            } catch {
                Self.logger.error("quit state save failed for profile \(profileId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Wakes every suspended page ahead of `closePagesBeforeQuit`, which cannot wait for the wake a teardown starts.
    /// True while a page is still waking: `completion` then runs once, when the last one is live.
    func resumePagesBeforeQuit(completion: @escaping () -> Void) -> Bool {
        let suspended = browserState.allTabIds().compactMap { browserState.liveEngine(forTab: $0) }.filter(\.isFrozen)
        // One more than the pages, released after the loop: a resume answering at once never ends the count early.
        var waking = suspended.count + 1
        for engine in suspended {
            engine.resume {
                waking -= 1
                if waking == 0 { completion() }
            }
        }
        waking -= 1
        return waking > 0
    }

    /// Closes every live page through its beforeunload, pagehide and unload handlers: a site writing its
    /// sign-in back to storage there would otherwise lose it when the quit kills the process.
    func closePagesBeforeQuit() {
        let engines = browserState.allTabIds().compactMap { browserState.liveEngine(forTab: $0) }
        // beforeunload first, waited for: its writes are then on their way before the exit stops the network
        // process, which would drop them. A page still suspended runs it in its teardown, unwaited.
        var running = 0
        for engine in engines where !engine.isFrozen {
            running += 1
            engine.runBeforeUnload { running -= 1 }
        }
        let deadline = Date().addingTimeInterval(0.5)
        while running > 0, Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
        for engine in engines { engine.teardown() }
    }

    @discardableResult
    func discardEngine(_ engine: WKWebViewTab) -> Any? {
        let state = engine.interactionState
        engine.teardown()
        return state
    }

    /// Closes a removed space's tab to extensions. Without this WebKit keeps an open extension tab whose
    /// web view is torn down, so content scripts and tab queries hit a zombie.
    func discardTabAdapter(_ adapter: TabExtensionAdapter) {
        (adapter.extensionWindow as? WindowExtensionAdapter)?.remove(tab: adapter)
        let registry = adapter.profileId.flatMap { profileContexts.existingContext(for: $0)?.extensions }
        registry?.controller.didCloseTab(adapter, windowIsClosing: false)
    }

    /// Opens a browser window on `spaceId`, cascaded from the active window unless a frame is given.
    @discardableResult
    func openWindow(on spaceId: UUID, opening: MainWindowController.Opening, frame: NSRect? = nil) -> MainWindowController {
        let frame = frame ?? windows.activeWindow?.window.map { $0.frame.offsetBy(dx: 24, dy: -24) }
        let controller = MainWindowController(context: self, launch: .space(spaceId, frame: frame, opening: opening))
        windows.add(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        scheduleWindowsSave()
        return controller
    }

    // MARK: - Engine lifecycle

    var lifecycleConfig: LifecyclePolicyConfig = .default

    /// One controller for every window: it trims the hidden spaces of the shared store, and asks
    /// each window to trim and sync the space it shows.
    private(set) lazy var hiddenSpaceLifecycle: HiddenSpaceLifecycleController = {
        let controller = HiddenSpaceLifecycleController(
            store: browserState,
            config: lifecycleConfig,
            discardEngine: { [weak self] in self?.discardEngine($0) },
            syncActiveState: { [weak self] in self?.windows.windows.forEach { $0.syncActiveBrowserState() } },
            trimActiveSpaceEngines: { [weak self] policy, cap in
                self?.windows.windows.forEach { $0.trimActiveSpace(policy: policy, cap: cap) }
            }
        )
        controller.onConstrainedPowerChange = { [weak self] constrained in
            // Low Power Mode / thermal pressure: no speculative prewarming, and no decorative animation
            // or backdrop blur in the chrome.
            self?.engineFactory.suppressWarmPool = constrained
            self?.windows.windows.forEach { $0.sendPowerMode(constrained) }
        }
        controller.onBatteryPowerChange = { [weak self] _ in
            // Nil until settings load, which applies the preset with the current power source.
            guard let preset = self?.settingsStore?.lifecyclePreset else { return }
            self?.applyLifecyclePreset(preset)
        }
        controller.onMemoryPressure = { [weak self] in self?.engineFactory.dropWarmPool() }
        controller.onBackgrounded = { [weak self] in
            self?.engineFactory.releaseWarmPool(after: .seconds(60))
            self?.windows.windows.forEach { $0.moveDockedCallToPanel() }
        }
        controller.onForegrounded = { [weak self] in
            guard let self else { return }
            windows.windows.forEach { $0.moveFloatingCallToDock() }
            let window = windows.activeWindow
            engineFactory.resumeWarmPool(
                dataStore: window?.tabManager.dataStore ?? engineFactory.defaultDataStore(),
                profileId: window?.tabManager.profileId
            )
        }
        controller.setupObservers()
        if controller.isConstrainedPower { engineFactory.suppressWarmPool = true }
        return controller
    }()

    /// Re-arms the idle sweep with new thresholds; called at startup and live on Settings change.
    func applyLifecyclePreset(_ preset: LifecyclePreset) {
        lifecycleConfig = .config(for: preset, onBatteryPower: hiddenSpaceLifecycle.isOnBatteryPower)
        hiddenSpaceLifecycle.applyConfig(lifecycleConfig)
    }

    /// Engines follow the foreground policy while any window is on screen.
    func windowVisibilityChanged() {
        let anyVisible = windows.windows.contains { $0.window?.occlusionState.contains(.visible) == true }
        guard anyVisible != hiddenSpaceLifecycle.isWindowVisible else { return }
        hiddenSpaceLifecycle.windowOcclusionChanged(isVisible: anyVisible)
    }

    /// Set when the app quits: windows closing then must not be forgotten.
    var isQuitting = false
    /// Set by applicationWillTerminate: everything is saved and the databases are closed.
    var isTerminating = false
    private var pendingWindowsSave: DispatchWorkItem?

    /// Debounced: moves, resizes and swipes report many intermediate states.
    func scheduleWindowsSave() {
        guard !isQuitting else { return }
        pendingWindowsSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let dbManager else { return }
            WindowStore(dbPool: dbManager.globalPool).replaceAllInBackground(storedWindows())
        }
        pendingWindowsSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func storedWindows() -> [StoredWindow] {
        windows.windows.compactMap { window in
            window.window.map { StoredWindow(frame: $0.frame, spaceId: window.tabManager.currentSpaceId) }
        }
    }

    /// Synchronous: the quit path saves before the process ends.
    func saveWindowsNow() {
        pendingWindowsSave?.cancel()
        pendingWindowsSave = nil
        guard let dbManager else { return }
        do {
            try WindowStore(dbPool: dbManager.globalPool).replaceAll(storedWindows())
        } catch {
            Self.logger.error("windows save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens a profile's pool, surfacing a failure to the user once per launch.
    func poolReportingFailure(for profileId: UUID) throws -> DatabasePool {
        do {
            return try dbManager.pool(for: profileId)
        } catch {
            Self.logger.error("profile database unavailable for \(profileId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            notifyProfileDatabaseFailure(profileId: profileId, error: error)
            throw error
        }
    }

    // MARK: - Database alerts

    /// Non-fatal cousin of `showFatalDatabaseAlert`: shown at most once per `subject` per launch.
    /// "Continue" keeps the current degraded behavior; "Quit" terminates. No automatic repair.
    func showDegradedDatabaseAlert(
        subject: String,
        message: String,
        informative: String,
        error: Error
    ) {
        guard notifiedDegradedDatabaseSubjects.insert(subject).inserted else { return }
        Self.logger.error("degraded database (\(subject, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        // A modal alert would block the test runner until it times out.
        guard !ProcessInfo.isRunningUnderXCTest else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "\(informative)\n\nError: \(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Continue".localized)
        alert.addButton(withTitle: "Quit".localized)
        if alert.runModal() == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }

    func notifyProfileDatabaseFailure(profileId: UUID, error: Error) {
        let name = profileManager?.profiles.first(where: { $0.id == profileId })?.name ?? profileId.uuidString
        showDegradedDatabaseAlert(
            subject: profileId.uuidString,
            message: String(format: "Lilo can't open the database for the profile \"%@\"".localized, name),
            informative: "Its tabs, history and downloads are unavailable this session.".localized,
            error: error
        )
    }

    func showFatalDatabaseAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Lilo can't open its database".localized
        alert.informativeText = String(
            format: "A database error occurred and automatic recovery failed. Please report this issue.\n\nError: %@".localized,
            error.localizedDescription
        )
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit".localized)
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Startup snapshot

    nonisolated private static func makeDatabaseBootstrap(appSupportDirectory: String) throws -> DatabaseBootstrap {
        let dbManager = try DatabaseManager(appSupportDirectory: appSupportDirectory)
        var startupSnapshot = try loadStartupSnapshot(from: dbManager.globalPool)
        startupSnapshot.storedSpaceIdsByProfile = try loadPreferredProfileSpaceIds(
            from: dbManager,
            snapshot: startupSnapshot
        )
        return DatabaseBootstrap(dbManager: dbManager, startupSnapshot: startupSnapshot)
    }

    nonisolated static func loadStartupSnapshot(from globalPool: DatabasePool) throws -> StartupSnapshot {
        return try globalPool.read { db in
            let profiles = try Profile.fetchAll(db)
            let spaces = try Space.order(Space.Columns.sortOrder).fetchAll(db)
            
            let windowBackgroundColor = try String.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: ["windowBackgroundColor"]
            )

            let lastActiveProfileId = try String.fetchOne(
                db,
                sql: "SELECT value FROM appState WHERE key = ?",
                arguments: ["lastActiveProfileId"]
            ).flatMap(UUID.init(uuidString:))

            return StartupSnapshot(
                profiles: profiles,
                spaces: spaces,
                lastActiveProfileId: lastActiveProfileId,
                storedSpaceIdsByProfile: [:],
                windowBackgroundColor: MainWindowController.normalizedCSSColor(windowBackgroundColor),
                windows: try WindowStore.load(db)
            )
        }
    }

    nonisolated private static func loadPreferredProfileSpaceIds(
        from dbManager: DatabaseManager,
        snapshot: StartupSnapshot
    ) throws -> [UUID: [String: UUID]] {
        guard let profileId = preferredProfileId(from: snapshot) else { return [:] }
        let pool = try dbManager.pool(for: profileId)
        let ids = try loadStoredSpaceIds(from: pool)
        return [profileId: ids]
    }

    nonisolated static func preferredProfileId(from snapshot: StartupSnapshot) -> UUID? {
        snapshot.lastActiveProfileId
            ?? snapshot.profiles.first(where: \.isDefault)?.id
            ?? snapshot.profiles.first?.id
    }

    nonisolated static func loadStoredSpaceIds(from pool: DatabasePool) throws -> [String: UUID] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT key, value FROM appState WHERE key IN (?, ?)",
                arguments: ["lastActiveSpaceId", "lastPersistentSpaceId"]
            )
            return rows.reduce(into: [String: UUID]()) { result, row in
                guard let key = row["key"] as String?,
                      let value = row["value"] as String?,
                      let spaceId = UUID(uuidString: value) else { return }
                result[key] = spaceId
            }
        }
    }
}

enum BrowserContextError: Error {
    case notBootstrapped
}

// MARK: - Space and profile changes

// Spaces and profiles are shared by every window: each change reaches all of them.
extension BrowserContext {
    func spaceManager(_ manager: SpaceManager, didCreateSpace space: Space) {
        windows.windows.forEach { $0.spaceWasCreated(space) }
        windows.activeWindow?.profileContext?.sessionPersistence?.scheduleSave()
        if !space.isPrivate { keepAgentsSpacesLast(manager) }
    }

    func spaceManager(_ manager: SpaceManager, didDeleteSpace space: Space) {
        let showingWindows = windows.windows(showing: space.id)
        // A shown space's engines live in its shared host and leave with the first window's discard.
        browserState.removeSpace(
            id: space.id,
            discardEngine: showingWindows.isEmpty ? { [self] in discardEngine($0) } : nil,
            discardTabAdapter: discardTabAdapter
        )
        recentlyClosed.removeAll(inSpace: space.id)
        tabArchive.entries.removeAll { $0.spaceId == space.id }
        if space.isPrivate {
            profileManager.releaseEphemeralDataStore(for: space.id)
            downloadManager.forgetPrivateDownloads(inSpace: space.id)
        }
        windows.windows.forEach { $0.spaceWasDeleted(space, by: manager) }
        // Each window goes back to the user space it last showed; an Agents space only when nothing else is left.
        let agentsSpaceIds = settingsStore.agentsSpaceIds
        let userSpaceIds = Set(manager.spaces.filter { !$0.isPrivate && !agentsSpaceIds.contains($0.id) }.map(\.id))
        for window in showingWindows {
            let replacement = window.recentSpaceIds.first(where: userSpaceIds.contains)
                ?? manager.spaces.first { userSpaceIds.contains($0.id) }?.id
                ?? manager.spaces.first?.id
            if let replacement { window.switchToSpace(replacement) }
        }
        windows.activeWindow?.profileContext?.sessionPersistence?.scheduleSave()
    }

    func spaceManager(_ manager: SpaceManager, didUpdateSpace space: Space) {
        windows.windows.forEach { $0.spaceWasUpdated(space) }
        windows.activeWindow?.profileContext?.sessionPersistence?.scheduleSave()
    }

    /// Only a space created while no window shows any space reaches here: a window switches itself.
    func spaceManager(_ manager: SpaceManager, didActivateSpace id: UUID) {
        windows.windows.filter { $0.tabManager.currentSpaceId == nil }.forEach { $0.switchToSpace(id) }
    }

    /// The Agents spaces stay after the user's own spaces, where the bar draws them apart. True when one
    /// had to move.
    @discardableResult
    private func keepAgentsSpacesLast(_ manager: SpaceManager) -> Bool {
        let agentsSpaceIds = settingsStore.agentsSpaceIds
        guard let lastUserSpace = manager.spaces.lastIndex(where: { !$0.isPrivate && !agentsSpaceIds.contains($0.id) }),
              let misplaced = manager.spaces[..<lastUserSpace].first(where: { agentsSpaceIds.contains($0.id) }) else { return false }
        // One at a time: each move reports back here, which moves the next.
        try? manager.moveSpace(id: misplaced.id, toIndex: .max)
        return true
    }

    func spaceManager(_ manager: SpaceManager, didReorderSpaces spaces: [Space]) {
        // The move back reports the final order itself.
        guard !keepAgentsSpacesLast(manager) else { return }
        StartupMetrics.trace("space-dnd", "stage=delegateDidReorderSpaces order=\(StartupMetrics.spaceOrderDescription(spaces))")
        windows.windows.forEach { $0.spacesWereReordered(spaces) }
        windows.activeWindow?.profileContext?.sessionPersistence?.scheduleSave()
    }
}

extension BrowserContext {
    func profileManager(_ manager: ProfileManager, didCreateProfile profile: Profile) {
        windows.windows.forEach { $0.profileWasCreated(profile) }
    }

    func profileManager(_ manager: ProfileManager, didDeleteProfile profile: Profile) {
        profileContexts.removeContext(for: profile.id)
        windows.windows.forEach { $0.profileWasDeleted(profile) }
    }

    func profileManager(_ manager: ProfileManager, didUpdateProfile profile: Profile) {
        windows.windows.forEach { $0.profileWasUpdated(profile) }
    }

    func profileManager(_ manager: ProfileManager, didActivateProfile id: UUID) {
        windows.windows.forEach { $0.profileWasActivated(id) }
    }
}

// MARK: - App-wide observers

// Installed once, whatever the number of windows: each event goes to the window it concerns.
extension BrowserContext {
    /// Bridges DownloadManager activity to chrome.downloads.on{Created,Changed,Erased}, for the extensions of the download's
    /// own profile. Every download source converges on DownloadManager's observer chokepoint, so one observer covers user- and
    /// extension-initiated downloads. onChanged diffs only `DownloadGapEventTracker.diffFields`.
    private func installDownloadGapEventObservers() {
        let tracker = DownloadGapEventTracker()
        downloadManager.addObserver { [weak self] item in
            guard let self, let id = item.id, !downloadManager.isPrivateDownload(id: id) else { return }
            // Ids are per profile database.
            let key = DownloadGapEventTracker.Key(profileId: item.profileId, id: id)
            // Bookkeeping runs for every download so an extension loaded later never sees a stale
            // onCreated; only the emit is gated on a listener being present.
            let previous = tracker.lastItems.updateValue(item, forKey: key)
            if previous == nil, tracker.lastItems.count > DownloadGapEventTracker.pruneThreshold { tracker.pruneFinished(keeping: key) }
            // Progress ticks only move bytes, which no diff field reports: skip them before building
            // any Chrome dictionary or resolving listeners.
            if let previous, previous.state == item.state, previous.destinationPath == item.destinationPath,
               previous.error == item.error, previous.fileMissing == item.fileMissing, previous.endedAt == item.endedAt {
                return
            }
            let registry = item.profileId.flatMap { self.profileContexts.existingContext(for: $0)?.extensions }
            let hasListener = registry.map { !$0.extensionIds(withPermission: "downloads").isEmpty } ?? false
            let current = DownloadsBridgeHandler.chromeDownloadItem(item)
            guard let previous else {
                // An item started before the prune horizon was already announced, then pruned.
                if hasListener, item.startedAt > tracker.pruneHorizon {
                    registry?.emitGapEvent("downloads", "onCreated", args: [current], requiredPermission: "downloads")
                }
                return
            }
            let prev = DownloadsBridgeHandler.chromeDownloadItem(previous)
            var delta: [String: Any] = ["id": Int(id)]
            var changed = false
            for field in DownloadGapEventTracker.diffFields where !downloadChromeFieldEqual(prev[field], current[field]) {
                delta[field] = ["previous": prev[field] ?? NSNull(), "current": current[field] ?? NSNull()]
                changed = true
            }
            if changed, hasListener {
                registry?.emitGapEvent("downloads", "onChanged", args: [delta], requiredPermission: "downloads")
            }
        }
        downloadManager.onErased = { [weak self] id, profileId in
            tracker.lastItems[DownloadGapEventTracker.Key(profileId: profileId, id: id)] = nil
            guard let self else { return }
            windows.windows.forEach { $0.bridgeRouter?.send(event: "downloadErased", data: ["id": Int(id)]) }
            guard !downloadManager.isPrivateDownload(id: id), let profileId else { return }
            profileContexts.existingContext(for: profileId)?.extensions.emitGapEvent("downloads", "onErased", args: [Int(id)], requiredPermission: "downloads")
        }
    }
}

extension BrowserContext {
    /// Bridges every folder change, from the sidebar or an extension, to chrome.tabGroups events for the extensions of the
    /// space's profile; a private space's stay unseen.
    private func installTabGroupEventObserver() {
        browserState.onFoldersChanged = { [weak self] spaceId, old, new in
            guard let self, let space = spaceManager?.space(with: spaceId), !space.isPrivate,
                  let registry = profileContexts.existingContext(for: space.profileId)?.extensions else { return }
            engineFactory.tabGroupsHandler.foldersChanged(from: old, to: new, registry: registry)
        }
    }
}

/// Accumulator for chrome.downloads events: the last item per download id (onCreated fired for it,
/// and the base onChanged diffs against). Held by the observer closure.
private final class DownloadGapEventTracker {
    /// Discrete Chrome DownloadItem fields that warrant an onChanged. Byte-progress fields
    /// (bytesReceived/totalBytes/fileSize) are intentionally excluded: Chrome doesn't fire onChanged
    /// for raw progress, and including them would emit several events per second per active download.
    static let diffFields = ["state", "paused", "filename", "danger", "error", "exists", "endTime"]
    static let pruneThreshold = 200

    struct Key: Hashable {
        let profileId: UUID?
        let id: Int64
    }

    var lastItems: [Key: DownloadItem] = [:]
    /// The latest start among pruned items; a new download always starts after it.
    private(set) var pruneHorizon = Date.distantPast

    /// Interrupted items younger than this stay: they are usually resumed soon, and a pruned one
    /// would resume without its first onChanged.
    static let interruptedRetention: TimeInterval = 86_400

    /// Drops finished items, which only a rare later change (file removed, resume) would diff against.
    func pruneFinished(keeping key: Key) {
        let interruptedCutoff = Date().addingTimeInterval(-Self.interruptedRetention)
        for (tracked, item) in lastItems where tracked != key && (item.state == .complete
            || (item.state == .interrupted && (item.endedAt ?? item.startedAt) < interruptedCutoff)) {
            lastItems[tracked] = nil
            if item.startedAt > pruneHorizon { pruneHorizon = item.startedAt }
        }
    }
}

/// Equality for a single Chrome download field across snapshots (nil-aware; values are String/Bool/Int).
private func downloadChromeFieldEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return (x as? NSObject) == (y as? NSObject)
    default: return false
    }
}
