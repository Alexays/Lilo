import AppKit
import GRDB
import OSLog
import Security
import WebKit

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private final class LiloWindow: NSWindow {
    override var contentLayoutRect: NSRect {
        contentView?.bounds ?? super.contentLayoutRect
    }

    /// An agent tab this window does not show never takes the keyboard: WebKit asks for it when an
    /// agent click focuses a field, and granting it would pull focus from what the user is typing in.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView,
           let webView = sequence(first: view, next: \.superview).lazy.compactMap({ $0 as? WKWebView }).first,
           let controller = windowController as? MainWindowController,
           let engine = controller.tabManager.engineTab(forWebView: webView),
           engine.isAgentControlled, !controller.displayedTabIds.contains(engine.id) {
            return false
        }
        return super.makeFirstResponder(responder)
    }
}

private final class LiloContentView: NSView {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
}

/// Holds the page views. A page kept rendering under the shown one (a shared tab, an agent's tab, an
/// inspected tab) stays out of the accessibility tree, so VoiceOver reads only the page on screen.
final class ContentContainerView: NSView {
    /// Under a shown page smaller than the container (an agent set its viewport): an opaque backdrop in the
    /// frame color, so the agent pages kept rendering below it do not show around it.
    private let stage: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        return view
    }()

    var stageColor = NSColor.windowBackgroundColor {
        didSet { stage.layer?.backgroundColor = stageColor.cgColor }
    }

    /// Puts the stage right under `view`, the shown page, when it has a fixed size that leaves part of the
    /// container uncovered; takes it away otherwise. A fixed-size page that is not the shown one changes nothing.
    func updateStage(under view: NSView, fixedSize: Bool) {
        if fixedSize, subviews.last(where: { $0 !== stage }) !== view { return }
        guard fixedSize, view.superview === self, !view.frame.contains(bounds) else {
            stage.removeFromSuperview()
            return
        }
        stage.frame = bounds
        stage.layer?.backgroundColor = stageColor.cgColor
        addSubview(stage, positioned: .below, relativeTo: view)
    }

    override func accessibilityChildren() -> [Any]? {
        let shown = subviews.filter { !$0.isHidden }
        // Only what VoiceOver reads covers a page: the split focus ring sits on the pane it rings. The stage
        // reads as nothing but covers what is below it.
        let exposed = shown.map { $0 === stage || !NSAccessibility.unignoredChildren(from: [$0]).isEmpty }
        let uncovered = shown.indices.filter { index in
            // An agent's page keeps its own size and may run past the container; the panes of a
            // split above it cover it together.
            let cover = shown.indices[(index + 1)...].filter { exposed[$0] }.reduce(NSRect.null) { $0.union(shown[$1].frame) }
            return !cover.contains(shown[index].frame.intersection(bounds))
        }.map { shown[$0] }
        guard uncovered.count < shown.count else { return super.accessibilityChildren() }
        // A web view hands VoiceOver a remote element, not itself: resolve each kept view to what it exposes.
        return NSAccessibility.unignoredChildren(from: uncovered)
    }
}

final class MainWindowController: NSWindowController {
    nonisolated static let logger = Logger(liloCategory: "MainWindowController")

    static let defaultSidebarWidth: CGFloat = 260
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...480
    static let contentInset: CGFloat = 8
    /// Matches the 320px of `--sidebar-fitted-width` in the chrome UI's global.css.
    static let minimumContentWidth: CGFloat = 320
    /// These mirror `--top-strip-height`, `--page-toolbar-height`, `--bottom-dock-height` and `--bottom-dock-margin` in global.css.
    static let topStripHeight: CGFloat = 40
    static let pageToolbarHeight: CGFloat = 40
    static let bottomDockHeight: CGFloat = 52
    static let bottomDockMargin: CGFloat = 10
    /// Bounds main-thread archive encoding at switch and quit, and the disk footprint.
    static let maxPersistedInteractionStatesPerSpace = 10

    /// AppKit holds the delegate weakly, so the picker must be retained while its popover is up.
    var activeSharePicker: NSSharingServicePicker?
    /// The capture this window's screenshot editor shows, held by `ChromeUISchemeHandler`.
    var screenshotCaptureId: String?
    /// Captures copied, held by `ChromeUISchemeHandler` while their card can still open or save
    /// them, with the name each saves under.
    var copiedCaptures: [String: (image: URL, filename: String)] = [:]

    /// Sized to real memory headroom rather than a flat count: discarding a foreground tab costs a
    /// re-navigation, so a roomy machine keeps tabs live and lets memory pressure do the reclaiming.
    var adaptiveForegroundEngineBudget: Int {
        if context.hiddenSpaceLifecycle.isConstrainedPower { return context.lifecycleConfig.constrainedForegroundEngineBudget }
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let base: Int
        switch ramGB {
        case 32...: base = 24
        case 16..<32: base = 16
        default: base = 10
        }
        return max(1, Int((Double(base) * context.lifecycleConfig.foregroundEngineBudgetMultiplier).rounded()))
    }
    static let hitboxDebugDefaultsKey = "liloDebugHitboxes"

    struct PendingPermissionRequest {
        let id: UUID
        let tabId: UUID
        let type: String
        let origin: String
        /// Answers from private tabs are not remembered.
        let isPrivate: Bool
        let completion: (Bool) -> Void
        let timeoutWork: DispatchWorkItem
    }

    /// Decoded off the main thread during setupDatabase. Consumed once, keyed on the exact profile and
    /// space pair, so a wrong prediction just falls back to the sync load.
    struct PreloadedSpaceRestoreState: Sendable {
        let profileId: UUID
        let spaceId: UUID
        let tabState: SpaceTabState
        let interactionStates: [UUID: Data]
    }

    var preloadedSpaceRestoreState: PreloadedSpaceRestoreState?
    /// Background decode of the initial space's tab tree, launched during setupDatabase and awaited
    /// before the restore consumes preloadedSpaceRestoreState.
    var preloadedSpaceRestoreTask: Task<PreloadedSpaceRestoreState?, Never>?

    let context: BrowserContext
    /// What the window shows first: the restored session, or a space it was opened on.
    enum Launch: Equatable {
        case restoreSession
        case space(UUID, frame: NSRect?, opening: Opening)
    }
    /// What a window opened on a space shows on it.
    enum Opening: Equatable {
        case nothing
        case newTab
        case urls([URL])
        case tab(UUID)
    }
    let launch: Launch
    /// Context of the profile owning the displayed space; nil before the first space is shown.
    var profileContext: ProfileContext?
    /// While its import runs and until its page closes, tabs extensions open on their own stay in the background.
    var holdsExtensionTabsInBackground = false
    /// Tabs this window's content area shows (the active tab, or every pane of its split).
    var displayedTabIds: Set<UUID> = []
    /// Selected tab another window shows, offered back through the content placeholder.
    var placeholderTabId: UUID?
    /// The tab this window last selected in each space it left: it returns to it.
    var activeTabBySpace: [UUID: UUID] = [:]
    /// The spaces this window showed, most recent first: a deleted space hands the window back to them.
    var recentSpaceIds: [UUID] = []
    /// The tabs this window showed, most recent first, each with when it was left.
    var recentTabs: [(id: UUID, leftAt: Date?)] = []
    /// The modifiers held when the recent tabs switcher opened; nil while it is closed.
    var tabSwitcherModifiers: NSEvent.ModifierFlags?
    let chromeInteractiveZones = ChromeInteractiveZoneStore()
    // Built by the startup steps (setupBridgeEarly, setupViews), once the window exists.
    var bridgeRouter: BridgeRouter!
    let chromeWebView: OverlayWebView
    var contentContainerView: NSView!
    /// Keeps a backgrounded call visible: its web view moves into an always-on-top panel.
    let floatingTabPanel = FloatingTabPanelController()
    /// Page popups this window opened, keyed by their engine id.
    var pagePopups: [UUID: PagePopupController] = [:]
    /// Little windows this window opened, keyed by their engine id.
    var littleWindows: [UUID: LittleWindowController] = [:]
    /// The extension side panel docked right of the content.
    lazy var sidePanel = SidePanelController(window: self)
    /// The Changes peek over a terminal, if one is open.
    var changesPeek: (terminalId: UUID, peek: PagePeekView, view: ChangesView)?
    var changesPeekClosedByClick: (terminalId: UUID, time: TimeInterval)?
    /// Terminals whose "waiting for you" notification goes out on the next pass, and the text a
    /// program sent with its own notification, used as the body when the screen shows no question.
    var terminalAttentionPending = Set<UUID>()
    var terminalNotificationTexts: [UUID: (title: String, body: String)] = [:]
    /// Keeps a backgrounded call visible while the app is active: scaled dock in the sidebar.
    let tabDock = TabDockController()
    /// getDisplayMedia tab-share frame ferry (one session at a time).
    let tabShareSessions = TabShareSessionController()
    /// Pages awaiting a tab-share picker choice from the chrome UI, keyed by request id.
    var pendingTabSharePickerRequests: [String: (requester: WKWebView?, continuation: CheckedContinuation<TabSharePickerChoice, Never>)] = [:]
    /// Opaque native frame between the content web view and the chrome overlay. Click-through.
    var windowFrameView: WindowFrameView?

    // MARK: - Tab Management

    let tabManager: TabManager
    /// Inputs `syncActiveBrowserState` folds into the store, as of the last sync. Unchanged means the
    /// sync is skipped. Any input that is not cheaply checkable forces a sync, so a false skip is impossible.
    private var lastSyncedActiveStateSignature: ActiveStateSyncSignature?
    /// Tab whose activation the last `.activateTab` command already shipped to the chrome, so the
    /// runtime activation that follows it does not send a second patch.
    private var activationAnnouncedByCommand: UUID?
    /// Certificate exceptions accepted this session, keyed "host:port". The value is the SHA-256
    /// of the leaf certificate the user saw; empty until the next challenge for that key records it.
    var insecureTrustExceptions: [String: String] = [:]
    /// Tabs currently showing reader mode; toggling reloads the page to exit.
    var readerModeTabs: Set<UUID> = []
    lazy var pageTranslator = PageTranslator()
    lazy var splitPanes = SplitPanesController(controller: self)
    /// Last observed Command-key state, used to push hover-pill "open in background" hints.
    var lastCommandKeyDown = false
    /// The shortcut Settings is recording: the next key press binds it instead of reaching anything else.
    var recordingShortcutId: String?
    var sidebarWidth: CGFloat = MainWindowController.defaultSidebarWidth
    var sidebarExpandedWidth: CGFloat = MainWindowController.defaultSidebarWidth
    var sidebarVisible = true
    var tabLayout = TabLayout.cached
    var sidebarOverlayVisible = false
    var sidebarCollapseLocked = false
    var restoredStartupSpaceIdsByProfile: [UUID: [String: UUID]] = [:]
    var storedWindowBackgroundColor: String?
    /// Set while the chrome shows a Space that follows the wallpaper.
    var wallpaperColorObservers: [(NotificationCenter, NSObjectProtocol)] = []
    var sentWallpaperKey: String?
    /// The color applyWindowChromeColors last painted everywhere, so a resend of it is a no-op.
    var lastAppliedWindowChromeColor: NSColor?
    var didStartChromeUILoad = false
    var didReceiveChromeReady = false
    /// Last href pushed to the chrome overlay. WebKit reports the element under the pointer on every
    /// mouse move, so without this the sidebar would take one bridge message per move for a readout
    /// that only changes when the pointer crosses a link boundary.
    var lastHoveredLinkHref = ""
    var lastPreconnectedHost: String?
    /// Timestamps of chrome-UI reloads after a WebContent process death; bounds a crash-reload loop.
    var chromeReloadAttempts: [Date] = []
    static let chromeReloadMaxAttempts = 3
    static let chromeReloadAttemptWindow: TimeInterval = 60
    var didCompleteSessionRestore = false
    var pendingExternalURLs: [URL] = []
    var hasDispatchedChromeInitialState = false
    let trafficLightAnimator = TrafficLightAnimator()
    lazy var chromeInput = ChromeInputController(controller: self)
    /// Debounces sidebar-width persistence (SQLite + UserDefaults) off the live-resize drag loop.
    var pendingSidebarWidthPersistWork: DispatchWorkItem?
    var pendingWindowBackgroundPersistWork: DispatchWorkItem?
    var pendingWindowFrameSaveWork: DispatchWorkItem?
    var pendingActiveTabPersistWork: DispatchWorkItem?
    /// Last chrome-state visibility sent over the bridge, used to skip no-op windowChromeStateChanged sends.
    var lastSentTrafficLightsVisible: Bool?

    // MARK: - Extensions

    /// Site-permission prompts awaiting an answer, each bound to the tab that asked. WebKit's
    /// checked completion handlers crash if deallocated uninvoked, so entries only leave through
    /// finishPermissionRequest (UI answer, tab close, or the timeout backstop).
    var pendingPermissionRequests: [PendingPermissionRequest] = []
    /// Deny backstop for permission requests the UI never answers.
    var permissionRequestTimeout: TimeInterval = 90
    // Handoff state; driven by publishActiveTab in +Lifecycle.swift.
    var browsingActivity: NSUserActivity?
    var handoffURL: URL?
    var isPerformingSpaceSwitch = false
    var popupCloseHandlersByWebViewId: [ObjectIdentifier: () -> Void] = [:]
    let startupNonCriticalUICoordinator = StartupNonCriticalUICoordinator()
    lazy var browserRuntimeCoordinator = BrowserRuntimeCoordinator(
        tabManager: tabManager,
        browserStateStore: context.browserState,
        syncActiveBrowserState: { [weak self] in self?.syncActiveBrowserState() },
        emitBrowserChange: { [weak self] changes in self?.emitBrowserChangeToAllWindows(changes) },
        scheduleSave: { [weak self] in self?.profileContext?.sessionPersistence?.scheduleSave() }
    )
    lazy var faviconCoordinator = FaviconCoordinator(
        service: context.faviconService,
        applyFavicon: { [weak self] tabId, dataURL, color in
            self?.updateTabFavicon(faviconDataURL: dataURL, dominantColor: color, forTabId: tabId)
        }
    )
    func enqueueVisibleTabUpdate(_ tab: Tab?, includeFavicon: Bool = false) {
        guard let tab, isVisibleTab(tab.id),
              let spaceId = tab.spaceId ?? tabManager.currentSpaceId else { return }
        emitVisibleTabUpdate(tab, spaceId: spaceId, includeFavicon: includeFavicon)
    }

    /// Sent to every window showing the tab's space, each with its own selection.
    func emitVisibleTabUpdate(_ tab: Tab, spaceId: UUID, includeFavicon: Bool = false) {
        // Runtime patches omit the favicon (the UI keeps the one it has); favicon changes ship it.
        let payload = includeFavicon ? tab.bridgeData : tab.runtimePatchData
        sendTabUpdate(payload, spaceId: spaceId)
        for window in context.windows.windows(showing: spaceId) where window !== self {
            window.sendTabUpdate(payload, spaceId: spaceId)
        }
    }

    /// Ships only the fields that differ from what this window's chrome last received for the tab.
    private func sendTabUpdate(_ tabPayload: [String: Any], spaceId: UUID) {
        guard let id = tabPayload[TabBridgeField.id.rawValue] as? String else { return }
        var patch = tabPayload
        if let sent = sentTabPatches[id] {
            patch = [TabBridgeField.id.rawValue: id]
            for (key, value) in tabPayload where (sent[key] as? AnyHashable) != (value as? AnyHashable) {
                patch[key] = value
            }
            guard patch.count > 1 else { return }
            // The chrome falls back to the url for a blank title.
            if patch[TabBridgeField.title.rawValue] != nil {
                patch[TabBridgeField.url.rawValue] = tabPayload[TabBridgeField.url.rawValue]
            }
        }
        sentTabPatches[id, default: [:]].merge(tabPayload) { $1 }
        let event = BrowserChangePresenter.tabUpdatedEvent(tabPayload: patch, spaceId: spaceId, activeTabId: tabManager.activeOpenTabId)
        bridgeRouter.send(event: event.name, data: event.data)
    }

    /// Discards every engine but the visible tab, split panes, and tabs the lifecycle protects
    /// (audio, capture, restoration, Web Inspector). The tabs stay in the sidebar and reload on return.
    func sleepHiddenTabs() {
        context.browserState.trimInactiveEngines(
            excluding: nil,
            policy: .background,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: context.discardEngine
        )
        if tabManager.trimActiveSpaceEngines(maxLiveEngines: 1) {
            syncActiveBrowserState()
        }
    }

    func browserSnapshot(for spaceId: UUID, runtime: TabRuntimeSnapshot? = nil) -> BrowserStateStore.SpaceSnapshot {
        let runtime = runtime ?? tabManager.runtimeSnapshot()
        let tabs = runtime.tabs.filter { $0.spaceId == spaceId }
        let tabIds = Set(tabs.map(\.id))
        let state = tabManager.spaceTabState(
            forSpace: spaceId,
            activationHistory: context.browserState.space(id: spaceId)?.spaceTab.state.activationHistory ?? []
        )
        return BrowserStateStore.SpaceSnapshot(
            spaceTab: SpaceTab(spaceId: spaceId, state: state),
            engines: runtime.engines.filter { tabIds.contains($0.key) },
            tabAdapters: runtime.tabAdapters.filter { tabIds.contains($0.key) },
            interactionStates: runtime.savedInteractionStates.filter { tabIds.contains($0.key) },
            restoringTabIds: runtime.restoringTabIds.filter { tabIds.contains($0.key) },
            lastAccessedAt: Date()
        )
    }

    /// Equality means the sync would write back exactly what the store already holds. The runtime
    /// overlay is shared with the store by reference, so it is not an input.
    private struct ActiveStateSyncSignature: Equatable {
        let spaceId: UUID
        let engineHost: ObjectIdentifier
        let engineVersion: UInt64
        let activeTabId: UUID?
        let structureToken: UUID
    }

    private func activeStateSyncSignature(for spaceId: UUID) -> ActiveStateSyncSignature? {
        // Without the durable structure token the snapshot cannot be cheaply proven unchanged.
        guard let structureToken = context.browserState.space(id: spaceId)?.spaceTab.structureToken else {
            return nil
        }
        return ActiveStateSyncSignature(
            spaceId: spaceId,
            engineHost: ObjectIdentifier(tabManager.engineHost),
            engineVersion: tabManager.engineHost.mutationVersion,
            activeTabId: tabManager.activeTabId,
            structureToken: structureToken
        )
    }

    func syncActiveBrowserState() {
        guard let spaceId = tabManager.currentSpaceId else { return }

        // A nil signature always syncs.
        if let signature = activeStateSyncSignature(for: spaceId),
           signature == lastSyncedActiveStateSignature {
            return
        }

        // The store owns the durable tree; a full re-derive is only needed while it lacks the space.
        if !context.browserState.syncActiveSpaceRuntime(
            id: spaceId,
            activeTabId: tabManager.activeTabId,
            // Only the engine maps are read here; materializing the space's tabs would be wasted.
            runtime: tabManager.engineHost.snapshot(tabs: [], activeTabId: tabManager.activeTabId)
        ) {
            context.browserState.storeActiveSpace(id: spaceId, snapshot: browserSnapshot(for: spaceId))
        }
        lastSyncedActiveStateSignature = activeStateSyncSignature(for: spaceId)
    }

    /// Spaces whose full tab snapshots (favicons included) this window's chrome already received.
    /// Later full-state payloads for them omit the heavy base64 favicons and the UI keeps the ones
    /// it holds. Re-seeded by `sendInitialState`, cleared per space on an explicit resync request.
    var chromeFaviconSyncedSpaceIds: Set<UUID> = []
    /// Tab payloads by id as this window's chrome last received them through `tabUpdated`. Every other
    /// event that seeds a tab's state clears its entry, so the next patch after it is complete.
    var sentTabPatches: [String: [String: Any]] = [:]
    /// Extension rows by id as this window's chrome last received them; `extensionsChanged` ships only the diff.
    var sentExtensionRows: [String: [String: Any]] = [:]

    func emitBrowserChange(_ changes: BrowserChangeSet) {
        guard let event = BrowserChangePresenter.event(
            for: changes,
            omitFaviconsForSpaces: chromeFaviconSyncedSpaceIds
        ) else { return }
        if event.name == "browserStateChanged" {
            chromeFaviconSyncedSpaceIds.formUnion(changes.states.map(\.spaceId))
            sentTabPatches.removeAll(keepingCapacity: true)
        } else if !sentTabPatches.isEmpty, let operations = event.data["operations"] as? [[String: Any]] {
            // A sidebar patch reseeds only the tabs it upserts or removes.
            for operation in operations {
                for tab in operation["upsertTabs"] as? [[String: Any]] ?? [] {
                    if let id = tab[TabBridgeField.id.rawValue] as? String { sentTabPatches[id] = nil }
                }
                for id in operation["removedTabIds"] as? [String] ?? [] { sentTabPatches[id] = nil }
            }
        }
        bridgeRouter.send(event: event.name, data: event.data)
    }

    /// A state mutation reaches every window showing a changed space; the others keep their own
    /// selection, since the store's active tab is the one this window just picked.
    func emitBrowserChangeToAllWindows(_ changes: BrowserChangeSet) {
        emitBrowserChange(changes)
        let changedSpaceIds = Set(changes.states.map(\.spaceId))
        for window in context.windows.windows where window !== self {
            guard let spaceId = window.tabManager.currentSpaceId, changedSpaceIds.contains(spaceId) else { continue }
            window.moveOnIfSelectionLeft()
            let selection = window.tabManager.activeOpenTabId
            window.emitBrowserChange(BrowserChangeSet(
                spaceId: changes.spaceId,
                stateChanges: changes.states.map { $0.spaceId == spaceId ? $0.selecting(selection) : $0 }
            ))
        }
    }

    func emitSpaceBrowserChange(spaceId: UUID, transitionId: String? = nil, profileId: UUID? = nil) {
        guard let state = context.browserState.browserSpaceChange(spaceId: spaceId) else {
            return
        }
        emitBrowserChange(BrowserChangeSet(
            spaceId: spaceId,
            stateChanges: [state],
            transitionId: transitionId,
            profileId: profileId
        ))
    }

    @discardableResult
    func applyBrowserCommand(_ command: BrowserCommand) throws -> BrowserChangeSet {
        // A terminal closed for good takes its saved screen along, shown or not.
        var closingTerminal: UUID?
        if case let .closeTab(_, tabId) = command, tabManager.tab(for: tabId)?.kind == .terminal { closingTerminal = tabId }
        // Unpinning a closed pinned tab, or unbookmarking a closed bookmark, takes it out of the sidebar: Undo and
        // Reopen Closed Tab bring it back, whichever path removed it.
        var removedTab: Tab?
        var wasPinned: Bool?
        if case let .setPinned(_, tabId, _) = command { wasPinned = tabManager.tab(for: tabId)?.isPinned }
        if case let .setPinned(_, tabId, false) = command, let tab = tabManager.tab(for: tabId), tab.isClosed, tab.isPinned { removedTab = tab }
        if case let .setBookmarked(_, tabId, false) = command, let tab = tabManager.tab(for: tabId), tab.isClosed, tab.isBookmarked { removedTab = tab }
        let removalRecorded = removedTab.map { recordClosedTabForRestore(id: $0.id) } ?? false
        let changes = try browserRuntimeCoordinator.apply(command)
        if removalRecorded, let removedTab { announceUndoableClose(of: removedTab) }
        if let closingTerminal, tabManager.tab(for: closingTerminal) == nil { tabManager.terminalHost.forget(closingTerminal) }
        if case let .activateTab(_, tabId) = command { activationAnnouncedByCommand = tabId }
        if case let .setPinned(_, tabId, isPinned) = command, wasPinned != isPinned, let adapter = tabManager.tabAdapter(for: tabId),
           let registry = tabManager.extensionRegistry, registry.hasLoadedExtensions {
            registry.controller.didChangeTabProperties(.pinned, for: adapter)
        }
        // Closing a tab, a folder or a whole space ends the shells it held.
        tabManager.terminalHost.prune { id in tabManager.tab(for: id).map { !$0.isClosed } ?? false }
        tabManager.changesHost.prune { id in tabManager.tab(for: id).map { !$0.isClosed } ?? false }
        discardCollapsedFolderEngines(after: command)
        // Activation lays the split out through showContentView; other commands can form or break one.
        if case .activateTab = command {} else if tabManager.activeSplit != splitPanes.split { layoutSplitContent() }
        // A tab the user moves out of an agent's folder goes back to normal, its fixed viewport included.
        if case .activateTab = command {} else { context.agentControl.refreshControlledTabs() }
        return changes
    }

    func isVisibleTab(_ id: UUID) -> Bool {
        guard let spaceId = tabManager.currentSpaceId else { return false }
        return context.browserState.space(spaceId, contains: id)
    }

    // MARK: - Init

    init(context: BrowserContext = BrowserContext(), launch: Launch = .restoreSession) {
        self.context = context
        self.launch = launch
        tabManager = TabManager(engineFactory: context.engineFactory, terminalHost: context.terminalHost, changesHost: context.changesHost)
        StartupMetrics.mark("mainWindowInitStart")
        var frame: NSRect?
        if case let .space(_, savedFrame, _) = launch { frame = savedFrame }
        let window = Self.makeWindow(frame: frame)
        // Own mark: NSWindow creation is ~30ms of the launch on its own, and without this the next
        // mark ("prewarmChromeWebView") reads as if the web view cost it.
        StartupMetrics.mark("mainWindowCreated")
        didStartChromeUILoad = Self._preloadedWebView != nil
        chromeWebView = Self._preloadedWebView ?? Self.makeChromeWebView(frame: .zero)
        Self._preloadedWebView = nil
        StartupMetrics.mark("prewarmChromeWebView")
        super.init(window: window)
        window.delegate = self
        chromeWebView.eventRouter = chromeInput.router
        chromeInput.router.routesDragToChrome = { [weak self] in self?.splitPanes.isLinkDrag($0) ?? false }
        tabManager.browserStateStore = context.browserState
        tabManager.delegate = self
        tabManager.engineDelegate = self
        setupTerminalHost()
        guard !ProcessInfo.isRunningUnderXCTest else { return }
        runStartupSequence()
    }

    private static let windowFrameKey = "liloWindowFrame"

    /// AppKit's frame autosave never persists this window (the key is absent after moves, resizes
    /// and zooms), so the frame is written by hand from the delegate callbacks and on quit.
    private static func savedWindowFrame() -> NSRect? {
        guard let s = UserDefaults.lilo.string(forKey: windowFrameKey) else { return nil }
        let r = NSRectFromString(s)
        guard !r.isEmpty,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) else { return nil }
        return r
    }

    /// The first window opens before the database does, so its frame is also kept in UserDefaults.
    func saveWindowFrame() {
        context.scheduleWindowsSave()
        guard context.windows.windows.first === self, let frame = window?.frame else { return }
        UserDefaults.lilo.set(NSStringFromRect(frame), forKey: Self.windowFrameKey)
    }

    private static func makeWindow(frame: NSRect?) -> NSWindow {
        let window = LiloWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lilo"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar makes AppKit center the traffic lights in the 52pt chrome header.
        // Buttons moved by hand go back to their default spot on every title change.
        window.toolbar = NSToolbar(identifier: "LiloChrome")
        window.toolbarStyle = .unified
        let contentView = LiloContentView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView
        window.backgroundColor = Self.defaultSidebarBackgroundColor()
        window.minSize = NSSize(width: 600, height: 400)
        if let saved = frame ?? savedWindowFrame() {
            window.setFrame(saved, display: false)
        } else {
            window.center()
        }
        window.identifier = NSUserInterfaceItemIdentifier("LiloMainWindow")
        window.restorationClass = MainWindowController.self
        return window
    }

    private func runStartupSequence() {
        // Synchronous: start chrome navigation before setupViews to give WebKit maximum warm-up time
        performStartupStep("restoreWindowChromeState", restoreWindowChromeState)
        syncTrafficLights(animated: false)
        performStartupStep("setupBridgeEarly", setupBridgeEarly)
        performStartupStep("loadChromeUI", loadChromeUI)
        performStartupStep("setupViews", setupViews)
        performStartupStep("setupKeyboardShortcuts", chromeInput.startMonitoring)

        // Heavy init runs while WebKit processes the first navigation; the yields keep its process-spawn
        // and navigation callbacks from starving behind the whole tail.
        Task { @MainActor in
            await performStartupStep("setupDatabase") {
                await setupDatabase()
            }
            reconcileBootstrapCacheWithDB()
            await Task.yield()
            performStartupStep("setupExtensions", setupExtensions)
            performStartupStep("setupDownloads", setupDownloads)
            performStartupStep("setupBridgeLate", setupBridgeLate)
            await Task.yield()
            // Consume the overlapped background tab-tree decode before restore reads it.
            preloadedSpaceRestoreState = await preloadedSpaceRestoreTask?.value
            if case let .space(spaceId, _, opening) = launch {
                openOnSpace(spaceId, opening: opening)
                return
            }
            StartupMetrics.mark("restoreSession")
            await restoreSession()
            await Task.yield()
            deleteOrphanedSpaceStates()
        }
    }

    private func performStartupStep(_ metric: String, _ step: () -> Void) {
        step()
        StartupMetrics.mark(metric)
    }

    private func performStartupStep(_ metric: String, _ step: () async -> Void) async {
        await step()
        StartupMetrics.mark(metric)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - TabManager.Delegate

extension MainWindowController: TabManager.Delegate {
    func tabManager(_ manager: TabManager, didActivateTab id: UUID) {
        noteRecentTab(id)
        defer {
            refreshPagePeeks()
            sidePanel.activeTabDidChange()
            if let changesPeek, changesPeek.terminalId != id { dismissChangesPeek() }
        }
        let announcedByCommand = activationAnnouncedByCommand == id
        activationAnnouncedByCommand = nil
        if let tab = manager.activeTab, let folder = manager.protectingFolder(of: tab), folder.isLocked {
            contentContainerView.subviews.forEach { $0.removeFromSuperview() }
            updateDisplayedTabs([])
            showContentPlaceholder(for: tab.id, lockedFolderId: folder.id)
            bridgeRouter.send(event: "trackersBlockedChanged", data: ["count": 0])
            publishActiveTab()
            return
        }
        // A blank tab never outlives its focus, unless it is another pane of the visible split.
        // A loading tab with no URL yet is a popup about to commit its first page, not a blank tab.
        defer {
            if didCompleteSessionRestore, !isPerformingSpaceSwitch {
                // Another window's selection, shown or offered back there, is not this window's to sweep.
                let keep = Set(manager.activeSplit?.layout.paneIds ?? [])
                    .union(context.browserState.displayedTabIds)
                    .union(context.windows.windows.compactMap { $0 === self ? nil : $0.tabManager.activeTabId })
                for tab in manager.openTabs where tab.id != id && !keep.contains(tab.id) && tab.kind == .web
                    && tab.url == nil && !tab.isLoading && !tab.isPinned && !tab.isBookmarked {
                    closeTabStateFirst(id: tab.id, undoable: false)
                }
            }
        }
        if let tab = manager.activeTab, tab.kind != .web {
            if tab.kind == .terminal { showTerminalView(for: tab) } else { showChangesTabView(for: tab) }
            // Nothing a page left on screen may outlive it: tracker count, Handoff.
            bridgeRouter.send(event: "trackersBlockedChanged", data: ["count": 0])
            publishActiveTab()
            if let spaceId = tab.spaceId { scheduleActiveTabPersist(id, spaceId: spaceId) }
            profileContext?.sessionPersistence?.scheduleSave()
            syncActiveBrowserState()
            guard didCompleteSessionRestore, !isPerformingSpaceSwitch else { return }
            if !announcedByCommand, let spaceId = tab.spaceId ?? manager.currentSpaceId {
                let event = BrowserChangePresenter.activationSidebarEvent(tab: tab, spaceId: spaceId)
                sentTabPatches[tab.id.uuidString] = nil
                bridgeRouter.send(event: event.name, data: event.data)
            }
            return
        }
        guard let engine = manager.engineTab(for: id),
              var tab = manager.activeTab else { return }
        // Background loads skip their fractional progress ticks (see didUpdateProgress).
        if tab.estimatedProgress != engine.estimatedProgress,
           let synced = updateRuntimeTab(id: id, mutate: { $0.estimatedProgress = engine.estimatedProgress }) {
            tab = synced
        }

        configureEngineIfNeeded(engine)
        showContentView(for: engine)
        // A blank tab has no page to type into and always opens with the command bar, so keyboard focus
        // belongs to the chrome. Handing it to the content view instead also blurs the command bar input.
        if tab.url == nil { focusChrome() } else { focusContent(engine.view) }
        // WKDownload resume needs a live web view to host it; keep it on the active tab.
        context.downloadManager.webView = engine.wkWebView
        bridgeRouter.send(event: "trackersBlockedChanged", data: ["count": engine.trackersBlocked])

        if let spaceId = tab.spaceId { scheduleActiveTabPersist(id, spaceId: spaceId) }
        profileContext?.sessionPersistence?.scheduleSave()
        syncActiveBrowserState()
        publishActiveTab()
        guard didCompleteSessionRestore, !isPerformingSpaceSwitch else { return }
        // Reclaim engines pushed past the active-space budget by this activation: active space only
        // (no hidden space changed), and debounced, so a burst of clicks collapses to one trim.
        context.hiddenSpaceLifecycle.scheduleActiveSpaceTrim()
        // Activation is a one-tab change: ship a sidebarChanged patch, not the full space state.
        // The command path already emitted its own; this covers the command-less activations
        // (space transfer, restore).
        if !announcedByCommand, let spaceId = tab.spaceId ?? manager.currentSpaceId {
            let event = BrowserChangePresenter.activationSidebarEvent(tab: tab, spaceId: spaceId)
            sentTabPatches[tab.id.uuidString] = nil
            bridgeRouter.send(event: event.name, data: event.data)
        } else if tab.isLoading {
            // A background load's progress never reached the chrome, and the command's diff does not carry it.
            enqueueVisibleTabUpdate(tab)
        }
    }

    /// Memory follows every click; a burst of clicks lands as one space-row write. Leaving the space
    /// (switch, window close) and quitting write the row themselves, so a pending write is never the only one.
    private func scheduleActiveTabPersist(_ tabId: UUID, spaceId: UUID) {
        context.spaceManager?.setActiveTab(tabId, forSpace: spaceId, persist: false)
        pendingActiveTabPersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Once the space is left, leaveSpace owns its row.
            guard let self, !context.isTerminating, tabManager.currentSpaceId == spaceId else { return }
            context.spaceManager?.setActiveTab(tabId, forSpace: spaceId)
        }
        pendingActiveTabPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func tabManager(_ manager: TabManager, didUpdateTab tab: Tab) {
        // Mute/mic-mute only touch the runtime overlay; a tabUpdated patch is enough for the UI.
        // syncActiveBrowserState + scheduleSave stay: they bake the overlay into durable state,
        // which is what persists mute across restarts.
        syncActiveBrowserState()
        publishActiveTab()
        enqueueVisibleTabUpdate(tab)
        if context.mediaTabs[tab.id] != nil { context.mediaActivityChanged() }
        profileContext?.sessionPersistence?.scheduleSave()
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {
    /// A running command keeps Lilo alive: the window hides instead of closing, and the Dock icon
    /// brings it back. With nothing running, closing it quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let host = tabManager.terminalHost
        // Shells outlive any window but the last one, which hides instead of quitting the app.
        guard context.windows.windows.count == 1, host.liveTabIds.contains(where: host.isBusy) else { return true }
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        context.windows.noteActive(self)
        // A tab another window took and has let go of since comes back without a click.
        if let placeholderTabId, context.windows.displayingWindow(ofTab: placeholderTabId) == nil {
            reclaimDisplayedTab(placeholderTabId)
        }
        if let profileContext, let spaceId = tabManager.currentSpaceId { bindExtensionRegistry(profileContext.extensions, spaceId: spaceId) }
        profileContext?.extensions.notifyWindowFocused(true)
        bridgeRouter?.send(event: "windowFocusChanged", data: ["focused": true])
        // Handoff offers the page of the window the user is in.
        browsingActivity?.becomeCurrent()
    }

    func windowDidResignKey(_ notification: Notification) {
        if tabSwitcherModifiers != nil { closeTabSwitcher(commit: false) }
        // An extension action popover taking key focus is not a real window blur: the popup's own
        // tabs.query/lastFocusedWindow calls must keep resolving to this window. Focus is
        // re-synced when the popover closes (ExtensionControllerDelegate.popoverDidClose).
        if profileContext?.extensions.delegate.hasOpenActionPopover == true { return }
        profileContext?.extensions.notifyWindowFocused(false)
        // The chrome UI cannot read this from its own DOM `blur`: that also fires when the content
        // WebView takes the first responder on a plain tab activation, with the window still key
        // (see lib/hoverClear.ts). Only the native window-key transition means "focus really left".
        bridgeRouter?.send(event: "windowFocusChanged", data: ["focused": false])
    }

    func windowDidResize(_ notification: Notification) {
        if fittedSidebarWidth != sidebarWidth { applySidebarLayout(animated: false) }
        if window?.inLiveResize == false { scheduleWindowFrameSave() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowFrame()
        reportBoundsChanged()
    }

    func windowDidMove(_ notification: Notification) {
        scheduleWindowFrameSave()
    }

    /// Debounced: a drag or a zoom animation reports many intermediate frames.
    private func scheduleWindowFrameSave() {
        pendingWindowFrameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveWindowFrame()
            self?.reportBoundsChanged()
        }
        pendingWindowFrameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// `windows.onBoundsChanged` for the space shown, once the frame settles as Chrome commits it. WebKit owns
    /// window ids, so it carries the window's place in `windows.getAll()`.
    private func reportBoundsChanged() {
        guard let spaceWindow = tabManager.windowAdapter, let registry = profileContext?.extensions else { return }
        let ids = registry.listeningExtensionIds("windows", "onBoundsChanged")
        guard !ids.isEmpty else { return }
        registry.emitPositioned("windows", "onBoundsChanged", to: ids) { extensionId in
            registry.windowPosition(of: spaceWindow, extensionId: extensionId).map { ["windowPosition": $0] }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit closes the windows after applicationWillTerminate: saving now would hit closed databases.
        guard !context.isTerminating else { return }
        saveWindowFrame()
        if let work = pendingActiveTabPersistWork {
            pendingActiveTabPersistWork = nil
            work.perform()
            work.cancel()
        }
        browsingActivity?.invalidate()
        browsingActivity = nil
        // WebKit must get an answer for every permission request; an open prompt dies with the window.
        for tabId in Set(pendingPermissionRequests.map(\.tabId)) { denyPermissionRequests(forTab: tabId) }
        pagePopups.values.forEach { $0.close() }
        // Their pages are served by this window's delegate methods.
        littleWindows.values.forEach { $0.window.close() }
        sidePanel.closeAll()
        setWallpaperColorWatch(false)
        // Closing the last window quits the app, after this window has left the registry.
        if context.windows.windows.count == 1 { saveSessionBeforeQuit() }
        if let spaceId = tabManager.currentSpaceId {
            syncActiveBrowserState()
            leaveSpace(spaceId, previousActiveTabId: tabManager.activeOpenTabId, nextSpaceId: nil)
        }
        context.windows.remove(self)
        context.profileContexts.pinnedProfileIds = Set(context.windows.windows.compactMap { $0.profileContext?.profileId })
        context.scheduleWindowsSave()
        teardownTabShare()
        screenshotCaptureId.map(ChromeUISchemeHandler.discardScreenshot)
        floatingTabPanel.dismiss()
        if let window {
            for profile in context.profileContexts.allContexts { profile.extensions.notifyWindowClosed(for: window) }
        }
        chromeInput.stop()
        // Whatever still holds this controller, the chrome page and its WebContent process end with the window.
        let close = NSSelectorFromString("_close")
        if chromeWebView.responds(to: close) { chromeWebView.perform(close) }
    }

    /// The empty toolbar only sizes the windowed title bar: shown for good in full screen, it would cover the
    /// sidebar's header. It comes down with the menu bar instead.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        syncTrafficLights(animated: false)
        bridgeRouter.send(event: "windowFullscreenChanged", data: ["isFullscreen": true])
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        syncTrafficLights(animated: false)
        bridgeRouter.send(event: "windowFullscreenChanged", data: ["isFullscreen": false])
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        let isVisible = window.occlusionState.contains(.visible)
        // A window loaded before its setup (an extension's windows.create) can hear this before it has a router.
        bridgeRouter?.isSilenced = !isVisible
        context.windowVisibilityChanged()
    }

    /// `isWindowVisible` boots true, and a window ordered in fully obscured never emits an occlusion change, so adopt the real state here.
    /// A lagging read is harmless: the sync has no side effects and the next occlusion notification corrects it.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        context.hiddenSpaceLifecycle.syncWindowVisibility(context.windows.windows.contains { $0.window?.occlusionState.contains(.visible) == true })
    }
}

extension MainWindowController: NSWindowRestoration {
    @MainActor
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        let delegate = NSApp.delegate as? AppDelegate
        if let existing = delegate?.mainWindowController { completionHandler(existing.window, nil) } else {
            let context = delegate?.browserContext ?? BrowserContext()
            let controller = MainWindowController(context: context)
            context.windows.add(controller)
            completionHandler(controller.window, nil)
        }
    }
}
