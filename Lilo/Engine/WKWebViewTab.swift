import AppKit
import OSLog
import ScreenTime
import Security
import WebKit

// MARK: - WKWebViewTab

@MainActor
final class WKWebViewTab: NSObject {
    /// Navigation event reported by a web engine tab.
    enum WebNavigationEvent: Sendable {
        case started(URL?)
        case committed(URL?)
        case finished(URL?)
        case failed(URL?, any Error)
    }

    struct WebPermissionUsageState: Sendable, Equatable {
        var usesCamera: Bool = false
        var usesMicrophone: Bool = false
        var isMicrophoneMuted: Bool = false
        var usesScreen: Bool = false

        static let none = Self()
    }

    enum WebNavigationHistoryDirection: Sendable {
        case back
        case forward
    }

    /// Delegate protocol for observing tab state changes.
    @MainActor
    protocol Delegate: AnyObject {
        func tab(_ tab: WKWebViewTab, didNavigate event: WebNavigationEvent)
        func tab(_ tab: WKWebViewTab, didUpdateTitle title: String?)
        func tab(_ tab: WKWebViewTab, didUpdateURL url: URL?)
        func tab(_ tab: WKWebViewTab, shouldAllowInsecureServerTrust trust: SecTrust, forHost host: String, port: Int) -> Bool
        /// Extensions' answer to a proxy's sign-in challenge, nil to prompt the user.
        func tab(
            _ tab: WKWebViewTab, authenticateProxy challenge: URLAuthenticationChallenge,
            completion: @escaping @MainActor (_ answer: (URLSession.AuthChallengeDisposition, URLCredential?)?) -> Void
        )
        func tab(_ tab: WKWebViewTab, didUpdateLoading isLoading: Bool)
        func tab(_ tab: WKWebViewTab, didUpdateProgress progress: Double)
        func tab(_ tab: WKWebViewTab, didUpdateCanGoBack canGoBack: Bool)
        func tab(_ tab: WKWebViewTab, didUpdateCanGoForward canGoForward: Bool)
        func tab(_ tab: WKWebViewTab, didCreateNewTab url: URL?, inBackground: Bool)
        /// Open a right-clicked link in a freshly created ephemeral private space and switch to it.
        func tab(_ tab: WKWebViewTab, openLinkInNewPrivateSpace url: URL)
        func tab(_ tab: WKWebViewTab, openLinkInNewWindow url: URL)
        /// Hides "Open Link in New Window" from the page's context menu.
        var prefersSingleWindow: Bool { get }
        func tabDidRequestClose(_ tab: WKWebViewTab)
        func tab(_ tab: WKWebViewTab, didStartDownload download: WKDownload)
        func tab(_ tab: WKWebViewTab, requestPermission type: String, forOrigin origin: String, completion: @escaping (Bool) -> Void)
        func tab(_ tab: WKWebViewTab, didUpdatePermissionUsage usage: WebPermissionUsageState)
        func tab(_ tab: WKWebViewTab, didUpdateAudioPlaying isPlaying: Bool)
        func tab(_ tab: WKWebViewTab, didUpdateFormDirty isDirty: Bool)
        func tab(_ tab: WKWebViewTab, didUpdateCallControls controls: CallControls)
        func tab(_ tab: WKWebViewTab, didChangeResponsive responsive: Bool)
        /// The page waits on a dialog held until its tab is shown, or no longer does.
        func tab(_ tab: WKWebViewTab, didUpdateAwaitingDialog isAwaiting: Bool)
        func tab(_ tab: WKWebViewTab, didUpdateTrackersBlocked count: Int)
        /// Stored per-site permission decision (granted/denied), or nil if undecided. Must NOT prompt.
        func tab(_ tab: WKWebViewTab, storedPermissionDecisionFor type: String, origin: String) -> Bool?
        /// Whether a page loaded at `url` runs JavaScript (chrome.contentSettings.javascript).
        func tab(_ tab: WKWebViewTab, allowsJavaScriptAt url: URL) -> Bool
        /// URL under the pointer, nil when it leaves a link. Drives the status-bar readout.
        func tab(_ tab: WKWebViewTab, didHoverLink href: String?)
        /// A service worker asks to foreground this tab (e.g. push-notification click).
        func tabRequestsForeground(_ tab: WKWebViewTab)
        /// The page handed us raw bytes to save to a file (blob/canvas export).
        func tab(_ tab: WKWebViewTab, saveData data: Data, suggestedFilename: String, mimeType: String, originatingURL: URL)
        /// The user asked to bookmark the current page (page context menu / Cmd+D).
        func tabRequestsBookmark(_ tab: WKWebViewTab)
        /// A non-web scheme (mailto:, tel:, slack:, ...) wants to open in an external app, pending user confirmation.
        func tab(_ tab: WKWebViewTab, launchExternalURL url: URL, fromPage pageURL: URL?)
        /// The loaded document's link icons, in document order. Every icon's `decide` must be called once.
        func tab(_ tab: WKWebViewTab, offersIcons icons: [LinkIcon])
        /// A followed link the window may show in a Peek instead: true when it took the link.
        func tab(_ tab: WKWebViewTab, peeksLink url: URL, modifierFlags: NSEvent.ModifierFlags) -> Bool
    }

    /// A link icon (`/favicon.ico` when the page declares none) WebKit loads on request through the
    /// page's own network session: its connections and cache, no credentials.
    struct LinkIcon {
        let url: URL
        /// Largest dimension in the `sizes` attribute, 0 when absent.
        let size: Int
        let isTouchIcon: Bool
        /// A receiver loads the icon and gets its bytes, or nil when the load fails; nil skips it.
        let decide: (((Data?) -> Void)?) -> Void
    }

    struct NavigationHistoryItem: Sendable {
        let title: String
        let url: URL
    }

    private static let logger = Logger(liloCategory: "navigation")

    private struct NavigationEmissionState {
        var url: URL?
        var title: String?
        var isLoading: Bool?
        var estimatedProgress: Double?
        var canGoBack: Bool?
        var canGoForward: Bool?
        var isAudioPlaying: Bool?
    }

    private enum NavigationEmissionTuning {
        static let progressStep: Double = 0.05
    }

    let id: UUID
    /// Idle-time fallback for a tab never shown (opened in the background), which has no `lastActiveAt`.
    let createdAt = Date()
    private let webView: WKWebView
    private var webInspectorRequestedAt: ContinuousClock.Instant?
    private var lastLoggedInteraction: (host: String, at: ContinuousClock.Instant)?
    private let findController: PageFindController
    let pip: PiPController
    private var permissionUsageState = WebPermissionUsageState.none
    private lazy var captureUsageObserver = CaptureUsageObserver(webView: webView) { [weak self] state in
        guard let self, state != self.permissionUsageState else { return }
        self.permissionUsageState = state
        self.delegate?.tab(self, didUpdatePermissionUsage: self.effectivePermissionUsageState)
    }

    /// True while this tab is the source of a getDisplayMedia tab-share ferry. Folded into the
    /// reported capture state so lifecycle protection, the pop-out panel, and the sidebar capture
    /// indicator all treat the shared tab as an ongoing capture.
    var isTabShareSource = false {
        didSet {
            guard isTabShareSource != oldValue else { return }
            delegate?.tab(self, didUpdatePermissionUsage: effectivePermissionUsageState)
        }
    }

    /// True while an agent drives this tab: it stays attached and rendering like a tab-share source.
    var isAgentControlled = false {
        didSet { screenTime?.suppressUsageRecording = suppressesScreenTimeUsage }
    }
    /// Set while an agent drives this tab: true when it took the page dialog, answered at once
    /// instead of opening a sheet on the user's window.
    var agentDialogHandler: ((String) -> Bool)?
    /// What the next file panel of this tab answers, without showing it: an agent's upload.
    var pendingAgentUploads: [URL]?
    /// The viewport an agent set with resize_window: it stays through every move of the view.
    var agentViewport: NSSize?

    /// Fills `bounds`, or keeps the agent's viewport: centered on an axis it is smaller on, like a device
    /// preview, else from the top left.
    func fitView(in bounds: NSRect) {
        guard let size = agentViewport else {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            view.layer?.cornerRadius = 0
            return
        }
        // Centered in the stage, the page sits away from the window frame's corner bites: it rounds its own.
        view.wantsLayer = true
        view.layer?.cornerRadius = WindowFrameView.contentCornerRadius
        view.layer?.masksToBounds = true
        let narrower = size.width < bounds.width, shorter = size.height < bounds.height
        var mask: NSView.AutoresizingMask = narrower ? [.minXMargin, .maxXMargin] : .maxXMargin
        mask.formUnion(shorter ? [.minYMargin, .maxYMargin] : .minYMargin)
        view.autoresizingMask = mask
        let x = narrower ? (bounds.midX - size.width / 2).rounded() : bounds.minX
        let y = shorter ? (bounds.midY - size.height / 2).rounded() : bounds.maxY - size.height
        view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    var effectivePermissionUsageState: WebPermissionUsageState {
        var state = permissionUsageState
        state.usesScreen = state.usesScreen || isTabShareSource
        return state
    }
    private lazy var contextMenuBuilder = ContextMenuBuilder(
        webView: webView,
        onOpenInNewTab: { [weak self] url in if let self { delegate?.tab(self, didCreateNewTab: url, inBackground: true) } },
        onOpenInPrivateSpace: { [weak self] url in if let self { delegate?.tab(self, openLinkInNewPrivateSpace: url) } },
        onOpenInNewWindow: { [weak self] url in if let self { delegate?.tab(self, openLinkInNewWindow: url) } },
        onTogglePiP: { [weak self] in self?.togglePictureInPicture() },
        onBookmark: { [weak self] in if let self { delegate?.tabRequestsBookmark(self) } },
        onDownload: { [weak self] url in self?.startContextMenuDownload(from: url) }
    )

    /// WebKit's native download context-menu items never fire WKDownloadDelegate, so ContextMenuBuilder
    /// routes them here to reach the same pipeline as navigation-initiated downloads.
    private func startContextMenuDownload(from url: URL) {
        webView.startDownload(using: Self.downloadRequest(for: url, pageURL: webView.url)) { [weak self] download in
            guard let self else { return }
            self.delegate?.tab(self, didStartDownload: download)
        }
    }

    /// Hotlink-protected CDNs 403 a Referer-less request. Only set for an http(s) page: a Referer naming
    /// a file:// or data: URL means nothing to a remote server.
    nonisolated static func downloadRequest(for url: URL, pageURL: URL?) -> URLRequest {
        var request = URLRequest(url: url)
        if let pageURL, let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
            request.mainDocumentURL = pageURL
        }
        return request
    }
    private let snapshotService: PageSnapshotService
    /// Subframes seen navigating, so a full-page capture can inject into a cross-origin iframe
    /// (see `PageSnapshotExpansion`). Bounded, because an ad-heavy page churns through frames;
    /// entries that have since died are harmless, evaluating against one just throws.
    private(set) var subframes: [WKFrameInfo] = []
    /// Last form-dirty state reported to the delegate; a committed navigation clears it, since the
    /// page that held the edits is gone.
    var isFormDirty = false
    /// Last call controls the page reported; a committed navigation clears them with the page's handlers.
    var callControls = CallControls()
    private static let maxTrackedSubframes = 32
    private static let supportsIntegrityPolicy = ["_networkConnectionIntegrityPolicy", "_setNetworkConnectionIntegrityPolicy:"]
        .allSatisfy { WKWebpagePreferences.instancesRespond(to: NSSelectorFromString($0)) }
    private static let supportsContentBlockersToggle = WKWebpagePreferences.instancesRespond(to: NSSelectorFromString("_setContentBlockersEnabled:"))
    /// `_WKWebsiteNetworkConnectionIntegrityPolicySanitizeLookalikeCharacters`, which WebKit maps to
    /// link decoration filtering.
    private static let linkDecorationFilteringPolicy: UInt = 1 << 8
    private var navigationStateObservations: [NSKeyValueObservation] = []
    private var isAudioPlayingObserverRegistered = false
    private var pendingMainFrameURL: URL?
    /// The pending main-frame navigation sends a body: a retry by URL would turn it into a GET without it.
    private(set) var pendingMainFrameSendsBody = false
    /// The pending main-frame navigation reads the HTTP cache only (see loadCachedCopy).
    private var isLoadingCachedCopy = false
    /// The failed page to reload on the next network change; set while that wait is registered.
    private var networkChangeRetryURL: URL?
    private var lastNavigationEmissionState = NavigationEmissionState()
    /// True once any main-frame navigation has committed. Stays false for a tab whose only navigation
    /// became a download (e.g. a target="_blank" download link), so that blank tab can auto-close.
    private(set) var hasCommittedContent = false
    /// Mirrors WebKit's suspended page: most WKWebView calls raise NSInternalInconsistencyException while
    /// it is set, and the exception unwinding through Swift corrupts the concurrency runtime.
    private(set) var isFrozen = false
    /// Set once beforeunload ran ahead of the teardown: the page leaves without asking, and only once.
    private var isLeaving = false
    /// When an extension last got this tab's web view: WebKit's `scripting.executeScript` evaluates in it after an
    /// async frame-tree round trip, and raises, crashing the app, if the page was suspended meanwhile.
    var lentToExtensionAt: Date?
    /// The content process died while the page was suspended or off screen: the engine is replaced when
    /// its tab is next shown (see TabManager.activateTabRuntime).
    private(set) var isPageLost = false
    /// The content process stopped answering. The page shows blurred and desaturated meanwhile: its last
    /// frame is all there is, WebKit cannot snapshot a page whose process does not answer.
    private(set) var isUnresponsive = false {
        didSet {
            guard isUnresponsive != oldValue else { return }
            // Off again once the page answers: a Core Image layer composites offscreen, which slows video down.
            webView.layerUsesCoreImageFilters = isUnresponsive
            webView.contentFilters = isUnresponsive ? [
                CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]),
                CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.3])
            ].compactMap { $0 } : []
            delegate?.tab(self, didChangeResponsive: !isUnresponsive)
            hiddenHangKill?.cancel()
            hiddenHangKill = nil
            guard isUnresponsive else { return }
            // Off screen nobody can reload it: a page stuck in a loop would burn a core until its tab closes.
            hiddenHangKill = Task { [weak self] in
                try? await Task.sleep(for: Self.hiddenHangLimit)
                guard let self, !Task.isCancelled, isUnresponsive, webView.window == nil, webView.responds(to: Self.killContentProcess) else { return }
                if !isPrivateBrowsing { Self.logger.info("kill process hung off screen host=\(self.currentURL?.host ?? "nil", privacy: .private)") }
                webView.perform(Self.killContentProcess)
            }
        }
    }
    private var hiddenHangKill: Task<Void, Never>?
    /// How long a page off screen may stay unresponsive before its process goes; it reloads when its tab shows.
    static var hiddenHangLimit: Duration = .seconds(30)
    private static let killContentProcess = NSSelectorFromString("_killWebContentProcessAndResetState")
    /// Host of the extension whose configuration built this web view; nil for a web page's. A web
    /// view never changes configuration, and an extension page loads only in its extension's.
    var extensionHost: String?
    private let freezer = CompositeFreezer()
    /// A second content-process death inside this window shows an error page instead of re-reloading.
    private static let contentTerminationRestrikeWindow: TimeInterval = 5
    private var lastContentTerminationAt: Date?
    /// One automatic reattempt per navigation: set when a transient provisional failure is retried,
    /// cleared on commit or on an explicitly requested load.
    private var didAutoRetryProvisionalLoad = false
    /// The navigation that last committed, to spot WebKit committing the same one twice (see didCommit).
    private weak var lastCommittedNavigation: WKNavigation?
    /// One reload per requested load for that double commit, so it can never loop.
    private var didReloadEmptyCommit = false
    /// Start of the current main-frame navigation, for the commit/finish timings in the log.
    private var navigationStartUptime: UInt64?
    private var navigationSignpost: PerfSignpostState?
    /// Trust presented by the main host on its latest challenge; what "Visit Anyway" pins the exception to.
    private(set) var lastServerTrust: SecTrust?
    /// The next main-frame load runs without content rule lists: the error page's "Visit Anyway" on a blocked page.
    var bypassesContentBlockersOnce = false
    /// Set once the page itself asked to close (window.close, or beforeunload answered "leave"),
    /// so the close path does not ask it again.
    private(set) var pageRequestedClose = false
    /// Holds the print-panel completion target alive for as long as the panel is up.
    private var pendingPrintProxy: PrintCompletionProxy?
    /// A page dialog raised while the tab was off screen, run with true once the tab is shown, false
    /// to dismiss it. The page is blocked until it is answered, and WebKit crashes on one never answered.
    private var queuedDialog: (@MainActor (Bool) -> Void)?
    /// Resource loads blocked by the content rule list on the current page (drives the "ads" badge).
    private(set) var trackersBlocked = 0
    private var trackerFlushScheduled = false
    /// Icons WebKit is offering, handed to the delegate once the burst is in.
    private var offeredIcons: [LinkIcon] = []

    func ownsWebView(_ candidate: WKWebView) -> Bool { webView === candidate }

    /// Asks WebKit whether the page may close now. False means a beforeunload handler is in the
    /// way: WebKit runs the confirm panel and calls webViewDidClose if the user leaves.
    func tryClose() -> Bool {
        // A suspended page runs no beforeunload handler, and WebKit refuses _tryClose on it.
        guard !isFrozen else { return true }
        return WebViewPrivateAccessors(webView).bool("_tryClose") ?? true
    }
    /// Chrome's transient activation: how long after the user's last click or key press a page may still open a window.
    private static let popupActivationWindow: TimeInterval = 5
    /// The web view the user last clicked or typed in, and when (event time): only one takes input at a time.
    private static weak var activatedWebView: WKWebView?
    private static var activationTime: TimeInterval = 0
    private static let activationMonitor: Any? = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    ) { event in
        let time = event.timestamp
        weak var window = event.window
        // Read after dispatch: a click makes the web view under it first responder.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var view = window?.firstResponder as? NSView
                while let current = view, !(current is WKWebView) { view = current.superview }
                activatedWebView = view as? WKWebView
                activationTime = time
            }
        }
        return event
    }
    var popupWebViewProvider: (@MainActor (WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?)?
    /// Set when the page asked for a Document Picture-in-Picture window: its next `window.open` becomes that window.
    var pendingDocumentPiPSize: NSSize?
    var documentPiPWebViewProvider: (@MainActor (WKWebViewConfiguration, NSSize) -> WKWebView?)?
    /// Closes the PiP window this page opened: it never outlives the page, which leaves on a commit or a teardown.
    var documentPiPCloser: (() -> Void)?

    /// Off, the page renders and runs timers at full rate though its window is hidden or covered: for a page that
    /// draws elsewhere, an agent's or a PiP window's.
    func setWindowOcclusionDetection(_ enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }

    /// A PiP request whose `window.open` never came must not outlive the page: its next popup would be taken for
    /// the PiP window.
    func cancelPendingDocumentPiP() {
        pendingDocumentPiPSize = nil
    }
    /// Called while building the context menu to inject extension-contributed menu items.
    /// Set by TabManager when the extension registry is active.
    var extensionContextMenuItemsProvider: (@MainActor () -> [NSMenuItem])?
    /// Back-reference set by TabManager so extension-tab conformance can query active/tab state.
    weak var tabManager: TabManager?
    weak var delegate: Delegate? {
        didSet {
            delegate?.tab(self, didUpdatePermissionUsage: effectivePermissionUsageState)
        }
    }

    var view: NSView { webView }
    var wkWebView: WKWebView { webView }
    var currentURL: URL? {
        Self.visibleURL(webViewURL: webView.url, pendingMainFrameURL: pendingMainFrameURL)
    }
    /// The target of an in-flight main-frame navigation that hasn't committed yet (the committed URL
    /// is still the old one). Nil once committed or when idle. Maps to Chrome's `tab.pendingUrl`.
    var provisionalURL: URL? {
        guard isLoading, let pending = pendingMainFrameURL, pending != webView.url else { return nil }
        return pending
    }
    var currentTitle: String? { webView.title }
    var isLoading: Bool { webView.isLoading }
    var estimatedProgress: Double { webView.estimatedProgress }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var interactionState: Any? { webView.interactionState }
    var pageZoom: Double { Double(webView.pageZoom) }
    /// `configuration` hands out a copy, and the data store of a web view never changes: read once.
    private(set) lazy var isPrivateBrowsing = !webView.configuration.websiteDataStore.isPersistent
    var supportsWebInspector: Bool { WebInspectorSupport.isAvailable(for: webView) }
    var processDiagnostics: WebViewProcessDiagnostics {
        let accessors = WebViewPrivateAccessors(webView)
        return WebViewProcessDiagnostics(
            webProcessIdentifier: accessors.pid("_webProcessIdentifier"),
            provisionalWebProcessIdentifier: accessors.pid("_provisionalWebProcessIdentifier"),
            networkProcessIdentifier: accessors.pid("_networkProcessIdentifier"),
            gpuProcessIdentifier: accessors.pid("_gpuProcessIdentifier"),
            modelProcessIdentifier: accessors.pid("_modelProcessIdentifier"),
            webProcessIsResponsive: accessors.bool("_webProcessIsResponsive"),
            webProcessState: accessors.int("_webProcessState"),
            isPictureInPictureActive: accessors.bool("_isPictureInPictureActive"),
            committedURL: accessors.urlString("_committedURL"),
            mainFrameURL: accessors.urlString("_mainFrameURL")
        )
    }

    func togglePictureInPicture() { pip.toggle() }

    /// An ongoing capture: the page is in a call, or the tab is a tab-share source.
    var hasActiveCapture: Bool {
        let usage = effectivePermissionUsageState
        return usage.usesCamera || usage.usesMicrophone || usage.usesScreen
    }

    /// A call, captured or not: a page offering a hangup or holding a live WebRTC connection is in one without mic or
    /// camera (Meet's companion mode).
    var isInCall: Bool { hasActiveCapture || callControls.isCall }

    /// Active media on the page: an ongoing capture (call) or audible playback.
    private var hasActiveMedia: Bool {
        hasActiveCapture || (lastNavigationEmissionState.isAudioPlaying ?? false)
    }

    /// Auto-enter PiP when the tab is backgrounded, if it has a PiP-able video with active media.
    func autoEnterPictureInPictureIfEligible() { pip.autoEnterIfEligible(hasActiveMedia: hasActiveMedia) }

    /// Undo only an auto-entered PiP when the tab returns to the foreground (leaves manual PiP alone).
    func restoreFromAutoPictureInPicture() { pip.restoreFromAuto() }

    /// Suspend this engine in place (cooperative Page-Visibility hide + media pause). Idempotent.
    /// `now` is the idle sweep's clock, so a simulated time also expires an extension's page loan.
    func freeze(now: Date = Date()) {
        guard !isFrozen, lentToExtensionAt.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return }
        isFrozen = true
        freezer.freeze(webView)
    }

    /// Resume a frozen engine. Idempotent; no-op if never frozen or if the page is lost.
    /// `completion` runs once WebKit has the page live again.
    func resume(completion: @escaping () -> Void = {}) {
        guard isFrozen, !isPageLost else { return completion() }
        isFrozen = false
        freezer.resume(webView, completion: completion)
    }

    /// Resumes the page ahead of a call WebKit refuses on a suspended one. False when the page is lost:
    /// the caller drops the call. The idle sweep refreezes a tab woken in the background.
    func wake() -> Bool {
        resume()
        return !isPageLost
    }
    var isWebInspectorVisible: Bool { WebInspectorSupport.isVisible(for: webView) }
    // The inspector reads not visible for a moment after show(); the recent request covers that gap.
    var shouldRetainForWebInspector: Bool {
        isWebInspectorVisible || webInspectorRequestedAt.map { ContinuousClock.now - $0 < .seconds(2) } ?? false
    }
    var isWebInspectorElementSelectionActive: Bool { WebInspectorSupport.isElementSelectionActive(for: webView) }
    var isWebInspectorPageProfilingActive: Bool { WebInspectorSupport.isPageProfilingActive(for: webView) }

    init(id: UUID = UUID(), webView: WKWebView) {
        self.id = id
        self.webView = webView
        self.snapshotService = PageSnapshotService(webView: webView)
        self.findController = PageFindController(webView: webView)
        self.pip = PiPController(webView: webView)
        super.init()

        WebInspectorSupport.enable(for: webView)
        // The base canvas stays opaque. A transparent one hides the white flash before first paint but lets
        // the themed container bleed through every page with no CSS background, which is worse.
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // WebKit's popup blocker drops a `window.open` that comes after the click's own task, as Meet's does after a
        // request: createWebViewWith gates popups on a recent user activation instead, as Chrome does.
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = Self.activationMonitor
        let setIconLoadingDelegate = NSSelectorFromString("_setIconLoadingDelegate:")
        if webView.responds(to: setIconLoadingDelegate) { webView.perform(setIconLoadingDelegate, with: self) }
        bindNavigationStateObservers()
        captureUsageObserver.start()
    }

    func loadURL(_ url: URL) {
        guard wake() else { return }
        if !isPrivateBrowsing { Self.logger.info("load source=app host=\(url.host ?? "nil", privacy: .private)") }
        pendingMainFrameURL = url
        pendingMainFrameSendsBody = false
        didAutoRetryProvisionalLoad = false
        didReloadEmptyCommit = false
        StartupMetrics.markOnce("firstContentLoadRequested")
        if url.isFileURL {
            // A plain URLRequest load silently no-ops for file URLs. An HTML page may read its own folder, for
            // the assets beside it; any other file (an SVG, a text file) only itself.
            let isPage = ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
            webView.loadFileURL(url, allowingReadAccessTo: isPage ? url.deletingLastPathComponent() : url)
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Tells a delegate set mid-load what a page loading out of sight did so far, as if it had watched:
    /// commit applies the site's settings, finish records the visit.
    func replayPreloadedNavigation() {
        guard let delegate else { return }
        let url = currentURL
        // First, while the tab still has no URL: the host change shows the site's cached icon, since
        // WebKit offered the page's own before anyone listened.
        delegate.tab(self, didUpdateURL: url)
        delegate.tab(self, didNavigate: .started(url))
        if hasCommittedContent { delegate.tab(self, didNavigate: .committed(url)) }
        if hasCommittedContent, !isLoading { delegate.tab(self, didNavigate: .finished(url)) }
        delegate.tab(self, didUpdateProgress: estimatedProgress)
    }

    /// Shows the copy of `url` in the HTTP cache, for a page the network cannot serve. WebKit reports
    /// a cache miss as a cancellation, surfaced as `NSURLErrorResourceUnavailable`.
    func loadCachedCopy(of url: URL) {
        guard wake() else { return }
        pendingMainFrameURL = url
        didAutoRetryProvisionalLoad = false
        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad))
    }

    /// False when the state holds no page, as for a tab whose first load never committed: WebKit then
    /// loads nothing and reports no failure.
    func restoreInteractionState(_ state: Any) -> Bool {
        webView.interactionState = state
        guard webView.backForwardList.currentItem != nil else { return false }
        if !isPrivateBrowsing { Self.logger.info("load source=session-state-restore host=\(self.webView.url?.host ?? "nil", privacy: .private)") }
        return true
    }

    /// Whether the page is currently playing audio (tracked via `_isPlayingAudio` KVO).
    var isPlayingAudio: Bool { lastNavigationEmissionState.isAudioPlaying ?? false }

    /// `_WKMediaMutedState.audioMuted` == 1. Native page-mute covers Web Audio + dynamically added
    /// media and persists across same-webview navigations, unlike per-element JS muting.
    func setMuted(_ muted: Bool) {
        guard wake() else { return }
        WebViewPrivateAccessors(webView).setUInt("_setPageMuted:", muted ? 1 : 0)
    }

    func setMicrophoneMuted(_ muted: Bool) {
        webView.setMicrophoneCaptureState(muted ? .muted : .active, completionHandler: nil)
    }

    func setCameraMuted(_ muted: Bool, completion: @escaping () -> Void) {
        webView.setCameraCaptureState(muted ? .muted : .active, completionHandler: completion)
    }

    func applyPageBackgroundColor(_ color: NSColor) {
        webView.underPageBackgroundColor = color
    }

    func goBack() {
        guard wake() else { return }
        webView.goBack()
    }

    func goForward() {
        guard wake() else { return }
        webView.goForward()
    }

    func navigationHistoryItems(for direction: WebNavigationHistoryDirection) -> [NavigationHistoryItem] {
        historyList(for: direction).map { NavigationHistoryItem(title: Self.historyTitle(for: $0), url: $0.url) }
    }

    func goToHistoryItem(at index: Int, direction: WebNavigationHistoryDirection) {
        let items = historyList(for: direction)
        guard items.indices.contains(index), wake() else { return }
        webView.go(to: items[index])
    }

    /// Opens a connection (DNS, TCP, TLS) to `url`'s server ahead of a likely navigation.
    func preconnect(to url: URL) {
        let selector = NSSelectorFromString("_preconnectToServer:")
        guard webView.responds(to: selector) else { return }
        webView.perform(selector, with: url)
    }

    /// Records a press on the page as user interaction for tracking prevention, once an hour per site.
    /// WebKit drops the interactions it sees itself, so its classifier would purge the cookies (and the
    /// sign-in) of sites the user does use. A no-op while tracking prevention is off.
    func logUserInteraction() {
        guard let url = webView.url, let host = url.host else { return }
        let now = ContinuousClock.now
        if let last = lastLoggedInteraction, last.host == host, now - last.at < .seconds(3600) { return }
        lastLoggedInteraction = (host, now)
        let store = webView.configuration.websiteDataStore
        let selector = NSSelectorFromString("_logUserInteraction:completionHandler:")
        guard store.responds(to: selector) else { return }
        typealias LogUserInteraction = @convention(c) (AnyObject, Selector, NSURL, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(store.method(for: selector), to: LogUserInteraction.self)(store, selector, url as NSURL) {}
    }

    func reload() {
        guard wake() else { return }
        // A hung process never gets to the reload: it goes, and the termination recovery loads the page again.
        if isUnresponsive, webView.responds(to: Self.killContentProcess) {
            if !isPrivateBrowsing { Self.logger.info("kill unresponsive process for reload host=\(self.currentURL?.host ?? "nil", privacy: .private)") }
            webView.perform(Self.killContentProcess)
            return
        }
        if !isPrivateBrowsing { Self.logger.info("load source=app-reload host=\(self.currentURL?.host ?? "nil", privacy: .private)") }
        webView.reload()
    }

    func reloadFromOrigin() {
        guard wake() else { return }
        if !isPrivateBrowsing { Self.logger.info("load source=app-reload-origin host=\(self.currentURL?.host ?? "nil", privacy: .private)") }
        webView.reloadFromOrigin()
    }

    /// A suspended page has nothing loading.
    func stopLoading() {
        guard !isFrozen else { return }
        isLoadingCachedCopy = false
        webView.stopLoading()
    }

    @discardableResult
    func showWebInspector() -> Bool {
        recordWebInspectorRequest(WebInspectorSupport.show(for: webView))
    }

    @discardableResult
    func showWebInspectorConsole() -> Bool {
        recordWebInspectorRequest(WebInspectorSupport.showConsole(for: webView))
    }

    @discardableResult
    func showWebInspectorResources() -> Bool {
        recordWebInspectorRequest(WebInspectorSupport.showResources(for: webView))
    }
    func toggleWebInspectorElementSelection() { _ = WebInspectorSupport.toggleElementSelection(for: webView) }
    func toggleWebInspectorPageProfiling() { _ = WebInspectorSupport.togglePageProfiling(for: webView) }

    private func recordWebInspectorRequest(_ didOpen: Bool) -> Bool {
        if didOpen { webInspectorRequestedAt = .now }
        return didOpen
    }

    func takeSnapshot(width: CGFloat? = nil) async -> NSImage? { await snapshotService.takeSnapshot(width: width) }
    /// Sized for the sidebar hover card (see PageSnapshotService.takeSnapshot(width:)). A frozen tab
    /// shows no preview: hovering down the sidebar must not thaw every tab it passes.
    func takePreviewSnapshot() async -> NSImage? {
        guard !isFrozen else { return nil }
        return await snapshotService.takeSnapshot(width: 240)
    }

    func takeFullPageSnapshot() async -> (image: NSImage, truncated: Bool)? {
        await snapshotService.takeFullPageSnapshot(subframes: subframes)
    }

    func startRegionSelection(completion: @escaping (CGRect?) -> Void) {
        snapshotService.startRegionSelection(completion: completion)
    }

    /// Cancels any region selection in flight on this tab (see `PageSnapshotService.cancelRegionSelection`).
    func cancelRegionSelection() {
        snapshotService.cancelRegionSelection()
    }

    func takeRegionSnapshot(rect: CGRect) async -> NSImage? {
        await snapshotService.takeRegionSnapshot(rect: rect)
    }

    /// Chrome's `tabs.ZoomSettings` an extension set: `mode` is automatic, manual or disabled, `scope`
    /// per-origin or per-tab. A committed navigation resets them, as in Chrome.
    struct ZoomSettings: Equatable {
        var mode = "automatic"
        var scope = "per-origin"
    }

    var zoomSettings = ZoomSettings()

    func setPageZoom(_ zoom: Double) {
        guard wake() else { return }
        let old = pageZoom
        webView.pageZoom = CGFloat(zoom)
        if pageZoom != old { reportZoomChange(from: old, to: pageZoom) }
    }

    /// `tabs.onZoomChange`; also sent alone for a zoom a manual-mode tab leaves to its extension.
    func reportZoomChange(from old: Double, to new: Double) {
        guard let registry = tabManager?.extensionRegistry, registry.hasLoadedExtensions else { return }
        let ids = registry.listeningExtensionIds("tabs", "onZoomChange")
        guard !ids.isEmpty, let adapter = tabManager?.tabAdapter(for: id) else { return }
        let settings = ["mode": zoomSettings.mode, "scope": zoomSettings.scope]
        registry.emitPositioned("tabs", "onZoomChange", to: ids) { extensionId in
            guard var change: [String: Any] = registry.tabPosition(of: adapter, extensionId: extensionId) else { return nil }
            change["oldZoomFactor"] = old
            change["newZoomFactor"] = new
            change["zoomSettings"] = settings
            return change
        }
    }

    /// `completion` resumes a page-initiated `window.print()`: the page's `afterprint` fires there,
    /// so it has to wait for the panel to close, which NSPrintOperation reports through a
    /// target/selector pair rather than a block.
    func printPage(in window: NSWindow?, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let window, let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            completion?()
            return
        }
        printInfo.isHorizontallyCentered = false; printInfo.isVerticallyCentered = false
        let op = webView.printOperation(with: printInfo)
        op.showsPrintPanel = true; op.showsProgressPanel = true
        guard let completion else {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return
        }
        let proxy = PrintCompletionProxy { [weak self] in
            self?.pendingPrintProxy = nil
            completion()
        }
        pendingPrintProxy = proxy
        op.runModal(
            for: window,
            delegate: proxy,
            didRun: #selector(PrintCompletionProxy.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    /// Screen Time's web usage and its parental limits; created with the first web page.
    /// Its view sits over the page to show the block screen and lets every event through otherwise.
    private var screenTime: STWebpageController?

    /// Test runs load throwaway pages that must never reach the user's Screen Time.
    static var reportsToScreenTime = !ProcessInfo.isRunningUnderXCTest

    /// Private spaces keep no history, and an agent's browsing is not the user's: Screen Time records neither.
    /// The parental limits still apply to both.
    private var suppressesScreenTimeUsage: Bool { isPrivateBrowsing || isAgentControlled }

    private func reportToScreenTime(_ url: URL?) {
        guard Self.reportsToScreenTime else { return }
        guard let url, url.scheme == "http" || url.scheme == "https" else {
            screenTime?.url = nil
            return
        }
        let controller = screenTime ?? {
            let controller = STWebpageController()
            controller.suppressUsageRecording = suppressesScreenTimeUsage
            controller.view.frame = webView.bounds
            controller.view.autoresizingMask = [.width, .height]
            webView.addSubview(controller.view)
            screenTime = controller
            return controller
        }()
        controller.url = url
    }

    /// Stop media, halt loading, detach the view and close the page through its handlers. Ends the engine for good.
    func teardown() {
        NotificationCenter.default.post(name: .webViewTabWillTearDown, object: self)
        documentPiPCloser?()
        cancelPendingDocumentPiP()
        let wasUnresponsive = isUnresponsive
        isUnresponsive = false
        cancelRegionSelection()
        // A suspended page is neither loading nor playing (freeze paused its media).
        if !isFrozen {
            webView.stopLoading()
            webView.pauseAllMediaPlayback()
        }
        webView.navigationDelegate = nil
        // A hung process never runs the close: it would keep spinning, and WebKit would keep handing it the
        // site's next pages. Killed after the delegate goes, so no termination recovery reloads it.
        if wasUnresponsive, webView.responds(to: Self.killContentProcess) {
            if !isPrivateBrowsing { Self.logger.info("kill unresponsive process for teardown host=\(self.currentURL?.host ?? "nil", privacy: .private)") }
            webView.perform(Self.killContentProcess)
        }
        runQueuedDialog(presenting: false)
        if isAudioPlayingObserverRegistered {
            webView.removeObserver(self, forKeyPath: "_isPlayingAudio")
            isAudioPlayingObserverRegistered = false
        }
        navigationStateObservations.removeAll()
        captureUsageObserver.stop()
        webView.removeFromSuperview()
        // Something can hold the web view for minutes after its tab is gone, and the page keeps
        // running meanwhile: its content scripts then message a tab extensions no longer know.
        // A suspended page runs no handler and WebKit rejects most calls on it: it is woken first.
        guard !isFrozen else {
            if !isPageLost { resume { [self] in closePage() } }
            return
        }
        closePage()
    }

    /// Runs the page's beforeunload handler ahead of a teardown the user cannot cancel, never asking to stay;
    /// `ran` follows it, as the web process answers the script after the handler.
    func runBeforeUnload(then ran: @escaping () -> Void) {
        isLeaving = true
        _ = tryClose()
        webView.evaluateJavaScript("0", in: nil, in: .defaultClient) { _ in ran() }
    }

    /// Closes the page through its beforeunload, pagehide and unload handlers: `_close` alone fires no
    /// beforeunload, where a site may write state back, such as its sign-in.
    private func closePage() {
        if !isLeaving { _ = tryClose() }
        let close = NSSelectorFromString("_close")
        if webView.responds(to: close) { webView.perform(close) }
    }

    func selectedTextForFind() async -> String? { await findController.selectedText() }

    func findInPage(_ query: String, caseSensitive: Bool) async -> Bool {
        await findController.find(query, caseSensitive: caseSensitive)
    }

    func findNext() { findController.findNext() }
    func findPrevious() { findController.findPrevious() }
    func dismissFind() { findController.dismiss() }

    private func bindNavigationStateObservers() {
        navigationStateObservations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let url = change.newValue else { return }
                self?.onMain { tab in
                    guard !Self.isSyntheticAboutBlank(webViewURL: url, pendingMainFrameURL: tab.pendingMainFrameURL) else { return }
                    // A failed provisional load clears the web view's URL: the pending one stays shown.
                    let nextURL = url ?? tab.pendingMainFrameURL
                    guard tab.lastNavigationEmissionState.url != nextURL else { return }
                    tab.lastNavigationEmissionState.url = nextURL; tab.pendingMainFrameURL = nextURL
                    tab.delegate?.tab(tab, didUpdateURL: nextURL)
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, change in
                guard let title = change.newValue else { return }
                self?.onMain { tab in
                    guard tab.lastNavigationEmissionState.title != title else { return }
                    tab.lastNavigationEmissionState.title = title; tab.delegate?.tab(tab, didUpdateTitle: title)
                }
            },
            observeNavigationState(\.isLoading, state: \.isLoading) { tab, v in
                tab.delegate?.tab(tab, didUpdateLoading: v)
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let v = change.newValue else { return }
                self?.onMain { tab in
                    if let last = tab.lastNavigationEmissionState.estimatedProgress,
                       abs(last - v) < NavigationEmissionTuning.progressStep, v < 1.0, last < 1.0 { return }
                    guard tab.lastNavigationEmissionState.estimatedProgress != v else { return }
                    if v >= 1.0 {
                        StartupMetrics.markOnce("firstContentProgressComplete")
                    }
                    tab.lastNavigationEmissionState.estimatedProgress = v; tab.delegate?.tab(tab, didUpdateProgress: v)
                }
            },
            observeNavigationState(\.canGoBack, state: \.canGoBack) { tab, v in
                tab.delegate?.tab(tab, didUpdateCanGoBack: v)
            },
            observeNavigationState(\.canGoForward, state: \.canGoForward) { tab, v in
                tab.delegate?.tab(tab, didUpdateCanGoForward: v)
            }
        ]
        // _isPlayingAudio is not in the public macOS SDK; use string-key KVO, only when WebKit still
        // has it, since KVO on a missing key raises.
        if webView.responds(to: NSSelectorFromString("_isPlayingAudio")) {
            webView.addObserver(self, forKeyPath: "_isPlayingAudio", options: [.initial, .new], context: nil)
            isAudioPlayingObserverRegistered = true
        }
    }

    /// KVO observer for a simple navigation-state property: dedupe against the last emitted
    /// value, store it, and forward to the delegate on the main actor.
    private func observeNavigationState<Value: Equatable & Sendable>(
        _ keyPath: KeyPath<WKWebView, Value>,
        state: WritableKeyPath<NavigationEmissionState, Value?> & Sendable,
        emit: @escaping @MainActor @Sendable (WKWebViewTab, Value) -> Void
    ) -> NSKeyValueObservation {
        webView.observe(keyPath, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            self?.onMain { tab in
                guard tab.lastNavigationEmissionState[keyPath: state] != v else { return }
                tab.lastNavigationEmissionState[keyPath: state] = v
                emit(tab, v)
            }
        }
    }

    // swiftlint:disable:next block_based_kvo
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        switch keyPath {
        case "_isPlayingAudio":
            let v = (change?[.newKey] as? Bool) ?? (change?[.newKey] as? NSNumber)?.boolValue ?? false
            onMain { tab in
                guard tab.lastNavigationEmissionState.isAudioPlaying != v else { return }
                tab.lastNavigationEmissionState.isAudioPlaying = v; tab.delegate?.tab(tab, didUpdateAudioPlaying: v)
            }
        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func historyList(for direction: WebNavigationHistoryDirection) -> [WKBackForwardListItem] {
        direction == .back
            ? Array(webView.backForwardList.backList.reversed())
            : webView.backForwardList.forwardList
    }

    private static func historyTitle(for item: WKBackForwardListItem) -> String {
        guard let t = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return Tab.fallbackTitle(for: item.url) }
        return t
    }

    nonisolated static func shouldIgnoreNavigationFailure(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return true }
        return isFrameLoadInterrupted(e)
    }

    enum NavigationFailureRecovery: Equatable {
        case retrySilently
        case surfaceAndRetryOnNetworkChange
        case surface
    }

    /// One silent reattempt: a refused, lost or timed-out connection, or a DNS lookup that got no answer,
    /// is usually a stale route, a broken HTTP/3 attempt or a lossy link. Past it, or offline, the page
    /// waits for the network to change. A host the DNS says does not exist is almost always a typo, and
    /// a load with a body is never replayed: a load by URL would drop it.
    nonisolated static func recoveryForNavigationFailure(
        _ error: Error,
        sendsBody: Bool,
        alreadyRetried: Bool,
        isNetworkPathSatisfied: Bool
    ) -> NavigationFailureRecovery {
        let e = error as NSError
        guard !sendsBody,
              e.domain == NSURLErrorDomain,
              Self.transientNetworkErrorCodes.contains(e.code),
              !isNonexistentHost(e)
        else { return .surface }
        return isNetworkPathSatisfied && !alreadyRetried ? .retrySilently : .surfaceAndRetryOnNetworkChange
    }

    nonisolated private static let transientNetworkErrorCodes: Set<Int> = [
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed
    ]

    /// The DNS answered that the name does not exist, as opposed to a lookup that timed out or failed on
    /// the way: kDNSServiceErr_NoSuchRecord or NoSuchName from Network, EAI_NONAME from CFNetwork.
    nonisolated private static func isNonexistentHost(_ error: NSError) -> Bool {
        if error.userInfo["_kCFStreamErrorDomainKey"] as? Int == 12, error.userInfo["_kCFStreamErrorCodeKey"] as? Int == 8 { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return underlying.domain == "kNWErrorDomainDNS" && [-65554, -65538].contains(underlying.code)
    }

    nonisolated private static func isFrameLoadInterrupted(_ error: NSError) -> Bool {
        guard error.code == 102 else { return false }
        return error.domain == WKError.errorDomain || error.domain == "WebKitErrorDomain"
    }

    nonisolated static func policyForNavigationResponse(
        _ response: URLResponse,
        isMainFrame: Bool,
        canShowMIMEType: Bool
    ) -> WKNavigationResponsePolicy {
        if canShowMIMEType { return .allow }
        // A main frame without a MIME type is a page, not a download: WebKit hands one over for a load it is not serving (null
        // response, no URL, just after the real commit), and a server omitting Content-Type still means a page.
        if isMainFrame, response.mimeType?.isEmpty ?? true { return .allow }
        if isMainFrame, isHTTPAuthChallenge(response as? HTTPURLResponse) { return .allow }
        return .download
    }

    /// `WKNavigationAction.buttonNumber` is a bitmask (left 1, right 2, middle 4), not `NSEvent.buttonNumber`'s index.
    nonisolated static let middleButtonNumber = 1 << 2

    /// The window's last mouse release, `buttonNumber` as `NSEvent` numbers it (middle 2).
    struct Click {
        let uptime: TimeInterval
        let buttonNumber: Int
        let modifierFlags: NSEvent.ModifierFlags
    }

    /// Chrome's rule for a new tab: Cmd or the middle button sends it behind, unless Shift brings it forward. WebKit gives a page's own window.open no event,
    /// where Chrome reads the input event being handled. The window's last release, `click`, stands in for it while the page is
    /// still handling a mouse event: the open runs from that click's handler, not from a timer or a later load.
    static func opensNewTabInBackground(_ action: WKNavigationAction, after click: Click?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if action.modifierFlags.contains(.command) || action.buttonNumber == middleButtonNumber { return !action.modifierFlags.contains(.shift) }
        guard action.navigationType == .other, let click, now - click.uptime < 1,
              WebViewPrivateAccessors(action).bool("_isUserInitiated") ?? true,
              action.sourceFrame.webView.flatMap({ WebViewPrivateAccessors($0).isProcessingMouseEvents() }) ?? true
        else { return false }
        return (click.modifierFlags.contains(.command) || click.buttonNumber == 2) && !click.modifierFlags.contains(.shift)
    }

    nonisolated static func shouldOpenLinkInBackgroundTab(
        url: URL?,
        isMainFrame: Bool,
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int
    ) -> Bool {
        guard isMainFrame,
              navigationType == .linkActivated,
              modifierFlags.contains(.command) || buttonNumber == middleButtonNumber,
              let scheme = url?.scheme?.lowercased()
        else { return false }
        return webSchemes.contains(scheme)
    }

    nonisolated private static func isHTTPAuthChallenge(_ response: HTTPURLResponse?) -> Bool {
        guard let response, response.statusCode == 401 else { return false }
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare("WWW-Authenticate") == .orderedSame else {
                continue
            }
            return !String(describing: value).isEmpty
        }
        return false
    }

    private func handleProvisionalNavigationFailure(_ error: Error) {
        let recovery = Self.recoveryForNavigationFailure(
            error,
            sendsBody: pendingMainFrameSendsBody,
            alreadyRetried: didAutoRetryProvisionalLoad,
            isNetworkPathSatisfied: NetworkPathStatus.shared.isSatisfied
        )
        guard recovery != .surface, let failedURL = pendingMainFrameURL ?? currentURL else {
            handleNavigationFailure(error, phase: "provisional")
            return
        }

        didAutoRetryProvisionalLoad = true
        let nsError = error as NSError
        if !isPrivateBrowsing {
            Self.logger.info("""
                auto-retrying provisional failure code=\(nsError.code, privacy: .public) \
                host=\(failedURL.host ?? "nil", privacy: .private) \
                waitingForNetworkChange=\(recovery == .surfaceAndRetryOnNetworkChange, privacy: .public)
                """)
        }

        switch recovery {
        case .retrySilently:
            scheduleAutomaticRetry(of: failedURL, afterDelay: 0.5)
        case .surfaceAndRetryOnNetworkChange:
            handleNavigationFailure(error, phase: "provisional")
            retryOnNetworkChange(failedURL)
        case .surface:
            break
        }
    }

    /// A committed page that lost its connection is not reloaded at once, which would drop what it shows,
    /// but on the next network change.
    private func handleCommittedNavigationFailure(_ error: Error) {
        handleNavigationFailure(error)
        guard let url = pendingMainFrameURL ?? currentURL,
              Self.recoveryForNavigationFailure(error, sendsBody: pendingMainFrameSendsBody, alreadyRetried: true,
                                                isNetworkPathSatisfied: NetworkPathStatus.shared.isSatisfied) != .surface
        else { return }
        retryOnNetworkChange(url)
    }

    /// One wait per tab, for its latest failed page: failures piling up before the change must not each reload it.
    private func retryOnNetworkChange(_ url: URL) {
        let isWaiting = networkChangeRetryURL != nil
        networkChangeRetryURL = url
        guard !isWaiting else { return }
        NetworkPathStatus.shared.runOnNextChange { [weak self] in
            guard let self, let url = self.networkChangeRetryURL else { return }
            self.networkChangeRetryURL = nil
            // Extra second lets DNS/DHCP settle on a freshly joined network.
            self.scheduleAutomaticRetry(of: url, afterDelay: 1.0)
        }
    }

    /// Reissues the failed load unless another navigation has started in the meantime.
    private func scheduleAutomaticRetry(of url: URL, afterDelay delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, (self.pendingMainFrameURL ?? self.currentURL) == url, self.wake() else { return }
                self.webView.load(URLRequest(url: url))
            }
        }
    }

    private func handleNavigationFailure(_ error: Error, phase: StaticString = "committed") {
        let failedURL = pendingMainFrameURL ?? currentURL
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
            .map { "\($0.domain) \($0.code) \($0.userInfo)" } ?? "none"
        if !isPrivateBrowsing {
            Self.logger.error("""
                navigation failed phase=\(phase, privacy: .public) \
                domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) \
                committed=\(self.hasCommittedContent, privacy: .public) \
                host=\(failedURL?.host ?? "nil", privacy: .private) \
                url=\(failedURL?.absoluteString ?? "nil", privacy: .private) \
                underlying=\(underlying, privacy: .public)
                """)
        }
        delegate?.tab(self, didNavigate: .failed(failedURL, error))
    }

    /// Closes the open page-load interval of a recorded session, with how it ended.
    private func endNavigationSignpost(_ result: String) {
        guard let navigationSignpost else { return }
        PerfSignposts.navigation.endInterval("load", navigationSignpost, result)
        self.navigationSignpost = nil
    }

    /// Restores an on-screen page instead of leaving a blank view. A second death within a few seconds
    /// surfaces an error page rather than looping.
    private func recoverFromContentProcessTermination() {
        endNavigationSignpost("processEnded")
        let now = Date()
        if !isPrivateBrowsing {
            Self.logger.error("""
                content process terminated host=\(self.currentURL?.host ?? "nil", privacy: .private) \
                committed=\(self.hasCommittedContent, privacy: .public) frozen=\(self.isFrozen, privacy: .public)
                """)
        }
        // WebKit only clears its suspended flag in resume(), which needs a running process. Respawning
        // off-screen pages the system killed under memory pressure would keep that pressure up.
        if isFrozen || webView.window == nil {
            isPageLost = true
            return
        }
        if let last = lastContentTerminationAt, now.timeIntervalSince(last) < Self.contentTerminationRestrikeWindow {
            lastContentTerminationAt = nil
            handleNavigationFailure(NSError(
                domain: "LiloEngine",
                code: NSURLErrorCannotLoadFromNetwork,
                userInfo: [NSLocalizedDescriptionKey: "This page repeatedly stopped responding and was not reloaded again."]
            ))
            return
        }
        lastContentTerminationAt = now
        // `reload()` silently no-ops without a committed back-forward item, leaving a blank view and no
        // failure delegate, so a tab that died before its first commit re-loads its known URL instead.
        if hasCommittedContent {
            webView.reload()
        } else if let url = currentURL {
            loadURL(url)
        } else {
            webView.reload()
        }
    }

    /// WebKit delivers navigation-delegate and KVO callbacks on the main thread, so run the
    /// main-actor work synchronously in the same turn rather than hopping through an async dispatch.
    nonisolated private func onMain(_ action: @MainActor (WKWebViewTab) -> Void) {
        MainActor.assumeIsolated { action(self) }
    }
}

// MARK: - WKWebViewTab.Delegate

extension WKWebViewTab.Delegate {
    func tab(_ tab: WKWebViewTab, openLinkInNewPrivateSpace url: URL) {}
    func tab(_ tab: WKWebViewTab, openLinkInNewWindow url: URL) {}
    var prefersSingleWindow: Bool { false }
    func tab(_ tab: WKWebViewTab, shouldAllowInsecureServerTrust trust: SecTrust, forHost host: String, port: Int) -> Bool { false }
    func tab(
        _ tab: WKWebViewTab, authenticateProxy challenge: URLAuthenticationChallenge,
        completion: @escaping @MainActor (_ answer: (URLSession.AuthChallengeDisposition, URLCredential?)?) -> Void
    ) { completion(nil) }
    func tab(_ tab: WKWebViewTab, didUpdateAudioPlaying isPlaying: Bool) {}
    func tab(_ tab: WKWebViewTab, didUpdateFormDirty isDirty: Bool) {}
    func tab(_ tab: WKWebViewTab, didUpdateCallControls controls: WKWebViewTab.CallControls) {}
    func tab(_ tab: WKWebViewTab, didChangeResponsive responsive: Bool) {}
    func tab(_ tab: WKWebViewTab, didUpdateAwaitingDialog isAwaiting: Bool) {}
    func tab(_ tab: WKWebViewTab, didUpdateTrackersBlocked count: Int) {}
    func tab(_ tab: WKWebViewTab, storedPermissionDecisionFor type: String, origin: String) -> Bool? { nil }
    func tab(_ tab: WKWebViewTab, allowsJavaScriptAt url: URL) -> Bool { true }
    func tab(_ tab: WKWebViewTab, didHoverLink href: String?) {}
    func tabRequestsForeground(_ tab: WKWebViewTab) {}
    func tab(_ tab: WKWebViewTab, saveData data: Data, suggestedFilename: String, mimeType: String, originatingURL: URL) {}
    func tabRequestsBookmark(_ tab: WKWebViewTab) {}
    func tab(_ tab: WKWebViewTab, launchExternalURL url: URL, fromPage pageURL: URL?) {}
    func tab(_ tab: WKWebViewTab, offersIcons icons: [WKWebViewTab.LinkIcon]) { icons.forEach { $0.decide(nil) } }
    func tab(_ tab: WKWebViewTab, peeksLink url: URL, modifierFlags: NSEvent.ModifierFlags) -> Bool { false }
}

// MARK: - WKNavigationDelegate

extension WKWebViewTab: WKNavigationDelegate {
    // WebKit calls this on the main thread; answer synchronously instead of paying the async
    // delegate variant's runloop hop per decision per frame.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        MainActor.assumeIsolated {
            // The configuration's default policies are frozen at creation, so the live settings are applied here.
            preferences.preferredHTTPSNavigationPolicy =
                WKEngineFactory.httpsOnlyEnabled ? .userMediatedFallbackToHTTP : .automaticFallbackToHTTP
            if #available(macOS 27, *) { preferences.globalPrivacyControlEnabled = WKEngineFactory.globalPrivacyControlEnabled }
            // Link tracking protection: strips click IDs (fbclid, gclid, ...) using the
            // system WebPrivacy list. OR'ed in: the same option set carries the HTTPS policy above.
            if Self.supportsIntegrityPolicy,
               let policy = preferences.value(forKey: "networkConnectionIntegrityPolicy") as? UInt {
                preferences.setValue(policy | Self.linkDecorationFilteringPolicy, forKey: "networkConnectionIntegrityPolicy")
            }
            // Keyed on the top-level page, as Chrome's javascript content setting is; frames inherit it.
            if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url, let delegate {
                preferences.allowsContentJavaScript = delegate.tab(self, allowsJavaScriptAt: url)
            }
            // WKWebpagePreferences._setContentBlockersEnabled:; holds through redirects, so their target page loads unfiltered too.
            if bypassesContentBlockersOnce, navigationAction.targetFrame?.isMainFrame != false {
                bypassesContentBlockersOnce = false
                if Self.supportsContentBlockersToggle { preferences.setValue(false, forKey: "contentBlockersEnabled") }
            }
            decisionHandler(policy(for: navigationAction), preferences)
        }
    }

    private func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            subframes.append(frame)
            if subframes.count > Self.maxTrackedSubframes { subframes.removeFirst() }
        }

        if isMainFrame {
            StartupMetrics.markOnce("firstContentNavigationPolicyRequested")
            // `type` separates a page or API reload from link clicks, history moves and JS location changes.
            if !isPrivateBrowsing {
                Self.logger.info("""
                    main-frame navigation type=\(navigationAction.navigationType.rawValue, privacy: .public) \
                    host=\(url?.host ?? "nil", privacy: .private)
                    """)
            }
        }

        if url?.scheme == "chrome-extension" && !isMainFrame {
            Self.logger.warning("[nav-policy] chrome-extension subframe url=\(url?.absoluteString ?? "nil", privacy: .private)")
        }

        // A tab in an extension's configuration loads only that extension's pages: WebKit drops the page's own navigation to
        // the web, which Chrome follows (WEBKIT-GAPS 96). The tab goes there as the app takes it, in a web page's engine.
        if isMainFrame, navigationAction.targetFrame != nil, extensionHost != nil, let url,
           url.scheme == "http" || url.scheme == "https", let tabManager {
            DispatchQueue.main.async { [weak tabManager, id] in tabManager?.load(url, inTab: id) }
            return .cancel
        }

        if Self.shouldOpenLinkInBackgroundTab(
            url: url,
            isMainFrame: isMainFrame,
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber
        ) {
            // Shift brings the new tab forward, as in Chrome and Safari.
            delegate?.tab(self, didCreateNewTab: url, inBackground: !navigationAction.modifierFlags.contains(.shift))
            return .cancel
        }

        // A link with `download`, or Option-clicked as in Safari and Chrome, must download even for viewable MIME types,
        // where the navigation-response policy would otherwise allow display.
        let optionClicked = navigationAction.navigationType == .linkActivated
            && navigationAction.modifierFlags.intersection([.option, .command]) == .option
        if navigationAction.shouldPerformDownload || optionClicked {
            if !isPrivateBrowsing {
                Self.logger.info("""
                    download from navigation action url=\(url?.absoluteString ?? "nil", privacy: .private) \
                    mainFrame=\(isMainFrame, privacy: .public)
                    """)
            }
            return .download
        }

        if isMainFrame, navigationAction.navigationType == .linkActivated, let url, url.scheme == "https" || url.scheme == "http",
           delegate?.tab(self, peeksLink: url, modifierFlags: navigationAction.modifierFlags) == true {
            return .cancel
        }

        // A nil target frame is a new-window navigation: its URL belongs to the popup, and taking it
        // here would repoint this tab's pending URL (retry target, TLS host check) at the popup's page.
        if navigationAction.targetFrame?.isMainFrame == true,
           !Self.isSyntheticAboutBlank(webViewURL: url, pendingMainFrameURL: pendingMainFrameURL) {
            pendingMainFrameURL = url
            pendingMainFrameSendsBody = (navigationAction.request.httpMethod ?? "GET").uppercased() != "GET"
            isLoadingCachedCopy = navigationAction.request.cachePolicy == .returnCacheDataDontLoad
        }

        // Set before the document's JS runs so `navigator.userAgent` reads Chrome. Per-tab by construction.
        if navigationAction.targetFrame?.isMainFrame == true {
            let wantsChrome = url.map(ChromeMasquerade.isStoreURL) ?? false
            let desired = wantsChrome ? ChromeMasquerade.chromeUserAgent : nil
            if webView.customUserAgent != desired {
                webView.customUserAgent = desired
            }
        }

        // Non-web schemes (slack://, mailto:, ...) route to the delegate, which confirms before launching so a page can't silently open other apps.
        if let url, let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            delegate?.tab(self, launchExternalURL: url, fromPage: webView.url)
            return .cancel
        }

        return .allow
    }

    nonisolated private static let webSchemes: Set<String> = [
        "http", "https", "about", "data", "blob", "javascript",
        "chrome-extension", "file", ViewSourceSchemeHandler.scheme
    ]

    private static func isAboutBlank(_ url: URL?) -> Bool {
        url?.absoluteString.caseInsensitiveCompare("about:blank") == .orderedSame
    }

    private static func isSyntheticAboutBlank(webViewURL: URL?, pendingMainFrameURL: URL?) -> Bool {
        guard isAboutBlank(webViewURL) else { return false }
        guard let pendingMainFrameURL else { return true }
        return !isAboutBlank(pendingMainFrameURL)
    }

    private static func visibleURL(webViewURL: URL?, pendingMainFrameURL: URL?) -> URL? {
        if isSyntheticAboutBlank(webViewURL: webViewURL, pendingMainFrameURL: pendingMainFrameURL) {
            return pendingMainFrameURL
        }
        return webViewURL ?? pendingMainFrameURL
    }

    nonisolated func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        onMain { tab in
            StartupMetrics.markOnce("firstContentServerRedirected")
            if let url = tab.currentURL { tab.pendingMainFrameURL = url }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onMain { tab in
            tab.navigationStartUptime = DispatchTime.now().uptimeNanoseconds
            tab.endNavigationSignpost("replaced")
            tab.navigationSignpost = PerfSignposts.navigation.beginInterval("load", id: PerfSignposts.navigation.makeSignpostID(from: tab))
            StartupMetrics.markOnce("firstContentNavigationStarted")
            tab.lastServerTrust = nil
            tab.delegate?.tab(tab, didNavigate: .started(tab.currentURL))
            // A pending region-selection overlay lives in the outgoing document; the new page won't
            // carry it forward, so cancel it now rather than leak its handler on the shared controller.
            tab.cancelRegionSelection()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onMain { tab in
            // When a response forces a process swap (COOP) before the web view committed anything, WebKit can
            // commit the navigation in the old process and again, as an empty document, in the new one.
            if let navigation, navigation === tab.lastCommittedNavigation, !tab.didReloadEmptyCommit,
               webView.url == nil || Self.isAboutBlank(webView.url),
               let url = tab.pendingMainFrameURL, url.scheme == "https" || url.scheme == "http" {
                tab.didReloadEmptyCommit = true
                if !tab.isPrivateBrowsing { Self.logger.notice("reloading an empty second commit host=\(url.host ?? "nil", privacy: .private)") }
                webView.load(URLRequest(url: url))
                return
            }
            tab.lastCommittedNavigation = navigation
            tab.documentPiPCloser?()
            tab.cancelPendingDocumentPiP()
            if tab.navigationSignpost != nil { PerfSignposts.navigation.emitEvent("commit") }
            if tab.isAgentControlled { WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(AgentCapture.consoleHook) }
            tab.hasCommittedContent = true
            tab.isPageLost = false   // a navigation brought an off-screen lost page back on its own
            tab.subframes.removeAll()
            if tab.isFormDirty {
                tab.isFormDirty = false
                tab.delegate?.tab(tab, didUpdateFormDirty: false)
            }
            if tab.callControls != CallControls() {
                tab.callControls = CallControls()
                tab.delegate?.tab(tab, didUpdateCallControls: tab.callControls)
            }
            // Clearing the crash-recency marker makes a later, unrelated termination count as a first failure
            // rather than tripping the died-twice guard.
            tab.lastContentTerminationAt = nil
            // A hung process killed for a reload never says it answers again: the new one committing does.
            tab.isUnresponsive = false
            tab.didAutoRetryProvisionalLoad = false
            tab.isLoadingCachedCopy = false
            tab.networkChangeRetryURL = nil
            tab.pendingMainFrameURL = tab.currentURL
            if !tab.isPrivateBrowsing {
                Self.logger.info("""
                    nav committed host=\(webView.url?.host ?? "nil", privacy: .private) \
                    ms=\(tab.navigationStartUptime.map { (DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000 } ?? 0, privacy: .public)
                    """)
            }
            tab.delegate?.tab(tab, didNavigate: .committed(tab.currentURL))
            tab.reportToScreenTime(webView.url)
            // A new page resets the blocked-tracker count; the send is skipped when it was already 0.
            if tab.trackersBlocked != 0 {
                tab.trackersBlocked = 0
                tab.delegate?.tab(tab, didUpdateTrackersBlocked: 0)
            }
            StartupMetrics.markOnce("firstContentCommitted")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onMain { tab in
            tab.pendingMainFrameURL = tab.currentURL
            if !tab.isPrivateBrowsing {
                Self.logger.info("""
                    nav finished host=\(webView.url?.host ?? "nil", privacy: .private) \
                    ms=\(tab.navigationStartUptime.map { (DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000 } ?? 0, privacy: .public)
                    """)
            }
            tab.navigationStartUptime = nil
            tab.endNavigationSignpost("finish")
            tab.delegate?.tab(tab, didNavigate: .finished(tab.currentURL))
            StartupMetrics.markOnce("firstContentFinished")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onMain { tab in
            tab.endNavigationSignpost("fail")
            guard !Self.shouldIgnoreNavigationFailure(error) else { return }
            tab.handleCommittedNavigationFailure(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onMain { tab in
            tab.endNavigationSignpost("fail")
            // A navigation taking over clears the flag in its policy check, so a cancellation left here is a cache miss.
            if tab.isLoadingCachedCopy, (error as NSError).code == NSURLErrorCancelled {
                tab.isLoadingCachedCopy = false
                tab.handleNavigationFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable), phase: "provisional")
                return
            }
            guard !Self.shouldIgnoreNavigationFailure(error) else { return }
            tab.handleProvisionalNavigationFailure(error)
        }
    }

    // WebKit calls the reason-carrying variant below when it is implemented and this one otherwise,
    // never both; this stays as the fallback should the private selector ever go away.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onMain { tab in
            // The PiP window shares the page's process: it would stay blank over everything.
            tab.documentPiPCloser?()
            tab.recoverFromContentProcessTermination()
        }
    }

    // Same event with the reason (WKNavigationDelegatePrivate): the app's own lifecycle trimming
    // raises memory pressure, so a kill and a real crash are worth telling apart in the log.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    nonisolated func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        onMain { tab in
            PerfSignposts.navigation.emitEvent("processEnded", Self.terminationReasonName(reason))
            if !tab.isPrivateBrowsing {
                Self.logger.error("""
                    content process ended reason=\(Self.terminationReasonName(reason), privacy: .public) \
                    host=\(webView.url?.host ?? "nil", privacy: .private)
                    """)
            }
            tab.recoverFromContentProcessTermination()
        }
    }

    /// `_WKProcessTerminationReason` from WKNavigationDelegatePrivate.h. The order is API, not ABI, so
    /// an unknown value is reported raw rather than mislabelled.
    nonisolated private static func terminationReasonName(_ reason: Int) -> String {
        switch reason {
        case 0: return "memoryLimit"
        case 1: return "cpuLimit"
        case 2: return "requestedByClient"
        case 3: return "crash"
        case 4: return "sharedProcessCrashLimit"
        default: return "unknown(\(reason))"
        }
    }

    // Paint milestones measured in the web process (WKNavigationDelegatePrivate). The commit/finish
    // timings above only bracket the network side; these say when the page actually showed up.
    @objc(_webView:didGeneratePageLoadTiming:)
    nonisolated func webView(_ webView: WKWebView, didGeneratePageLoadTiming timing: NSObject) {
        let date = { (key: String) in
            timing.responds(to: NSSelectorFromString(key)) ? timing.value(forKey: key) as? Date : nil
        }
        guard let start = date("navigationStart") else { return }
        let ms = { (key: String) in date(key).map { Int($0.timeIntervalSince(start) * 1000) } ?? -1 }
        let firstLayout = ms("firstVisualLayout")
        let firstPaint = ms("firstMeaningfulPaint")
        let document = ms("documentFinishedLoading")
        let subresources = ms("allSubresourcesFinishedLoading")
        let layoutAt = date("firstVisualLayout")
        let paintAt = date("firstMeaningfulPaint")
        onMain { tab in
            // Reported once the load settles, dated by the web process: the marks land when it painted.
            layoutAt.map { StartupMetrics.markOnce("firstContentLayout", occurredAt: $0.timeIntervalSince1970 * 1000) }
            paintAt.map { StartupMetrics.markOnce("firstContentPainted", occurredAt: $0.timeIntervalSince1970 * 1000) }
            guard !tab.isPrivateBrowsing else { return }
            Self.logger.info("""
                nav paints host=\(webView.url?.host ?? "nil", privacy: .private) \
                firstLayout=\(firstLayout, privacy: .public) firstPaint=\(firstPaint, privacy: .public) \
                document=\(document, privacy: .public) subresources=\(subresources, privacy: .public)
                """)
        }
    }

    // Swipe back/forward (WKNavigationDelegatePrivate): the document under the pointer slides away, so
    // the hovered-link readout must not keep pointing into it. The next mouse move re-reports.
    @objc(_webViewDidBeginNavigationGesture:)
    nonisolated func webViewDidBeginNavigationGesture(_ webView: WKWebView) {
        onMain { $0.delegate?.tab($0, didHoverLink: nil) }
    }

    // Same-document navigations (WKNavigationDelegatePrivate), which WKNavigationDelegate never
    // reports: they feed chrome.webNavigation.
    @objc(_webView:navigation:didSameDocumentNavigation:)
    nonisolated func webView(_ webView: WKWebView, navigation: WKNavigation?, didSameDocumentNavigation navigationType: Int) {
        onMain { $0.reportSameDocumentNavigation(type: navigationType) }
    }

    /// `type` is `_WKSameDocumentNavigationType`: 0 anchor, 1 push, 2 replace, 3 pop. WebKit owns the
    /// integer tab id, so the event carries the tab's window position and index for JS to resolve.
    private func reportSameDocumentNavigation(type: Int) {
        guard let registry = tabManager?.extensionRegistry else { return }
        let event = type == 0 ? "onReferenceFragmentUpdated" : "onHistoryStateUpdated"
        // The window and index lookups below are skipped when no extension listens.
        let ids = registry.gapEvents.listeners(among: registry.extensionIds(withPermission: "webNavigation"), namespace: "webNavigation", event: event)
        PerfSignposts.energy.emitEvent("sameDocNav", "\(ids.isEmpty ? "dropped" : "delivered")")
        guard !ids.isEmpty, let url = webView.url, let adapter = tabManager?.tabAdapter(for: id) else { return }
        let timeStamp = Date().timeIntervalSince1970 * 1000
        registry.emitPositioned("webNavigation", event, to: ids) { extensionId in
            guard var details: [String: Any] = registry.tabPosition(of: adapter, extensionId: extensionId) else { return nil }
            details["url"] = url.absoluteString
            details["timeStamp"] = timeStamp
            details["transitionQualifiers"] = type == 3 ? ["forward_back"] : []
            return details
        }
    }

    // Hung-tab detection (WKNavigationDelegatePrivate): surfaces the "page isn't responding" card.
    // A page-initiated print is exempt: `window.print()` blocks the page on the modal panel by
    // design, and WebKit keeps its responsiveness timer running through it.
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    nonisolated func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        onMain { tab in
            // A page waiting on a dialog, on screen or queued until its tab shows, is blocked by design too.
            guard tab.pendingPrintProxy == nil, tab.queuedDialog == nil, webView.window?.attachedSheet == nil else { return }
            tab.isUnresponsive = true
        }
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    nonisolated func webViewWebProcessDidBecomeResponsive(_ webView: WKWebView) {
        onMain { $0.isUnresponsive = false }
    }

    // Fires per blocked resource, so it is only worth the IPC because chrome updates are coalesced.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    nonisolated func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard action.responds(to: NSSelectorFromString("blockedLoad")),
              (action.value(forKey: "blockedLoad") as? NSNumber)?.boolValue == true else { return }
        MainActor.assumeIsolated { recordTrackerBlocked() }
    }

    // `_WKIconLoadingDelegate`: WebKit asks once per icon when the document loads, all in one burst,
    // on the main thread.
    @objc(webView:shouldLoadIconWithParameters:completionHandler:)
    func webView(
        _ webView: WKWebView,
        shouldLoadIconWithParameters parameters: NSObject,
        completionHandler: @escaping (((Data?) -> Void)?) -> Void
    ) {
        let value = { (key: String) in
            parameters.responds(to: NSSelectorFromString(key)) ? parameters.value(forKey: key) : nil
        }
        guard let url = value("url") as? URL else { return completionHandler(nil) }
        offeredIcons.append(LinkIcon(
            url: url,
            size: (value("size") as? NSNumber)?.intValue ?? 0,
            // _WKLinkIconType: 0 favicon, 1 touch icon, 2 precomposed touch icon.
            isTouchIcon: (value("iconType") as? Int ?? 0) != 0,
            decide: completionHandler
        ))
        guard offeredIcons.count == 1 else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let icons = offeredIcons
                offeredIcons = []
                if let delegate {
                    delegate.tab(self, offersIcons: icons)
                } else {
                    icons.forEach { $0.decide(nil) }
                }
            }
        }
    }

    private func recordTrackerBlocked() {
        trackersBlocked += 1
        guard !trackerFlushScheduled else { return }
        trackerFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trackerFlushScheduled = false
                self.delegate?.tab(self, didUpdateTrackersBlocked: self.trackersBlocked)
            }
        }
    }

    // WebKit calls this on the main thread; the server-trust challenge of every connection is
    // answered synchronously. Only the HTTP auth prompt (a sheet) stays off the delegate's stack.
    nonisolated func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        MainActor.assumeIsolated {
            let space = challenge.protectionSpace
            let method = space.authenticationMethod

            if method == NSURLAuthenticationMethodServerTrust,
               let trust = space.serverTrust {
                StartupMetrics.markOnce("firstContentTLSChallengeReceived")
                let challengedHost = space.host.lowercased()
                let pendingHost = pendingMainFrameURL?.host?.lowercased()
                let currentHost = currentURL?.host?.lowercased()
                guard challengedHost == pendingHost || challengedHost == currentHost else {
                    completionHandler(.performDefaultHandling, nil)
                    StartupMetrics.markOnce("firstContentTLSChallengeHandled")
                    return
                }
                lastServerTrust = trust
                if delegate?.tab(self, shouldAllowInsecureServerTrust: trust, forHost: challengedHost, port: space.port) == true {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
                StartupMetrics.markOnce("firstContentTLSChallengeHandled")
            } else if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
                if isAgentControlled {
                    // No sheet over the user's window: the agent signs in through the URL, once.
                    let url = pendingMainFrameURL ?? currentURL
                    if challenge.previousFailureCount == 0, url?.host?.lowercased() == space.host.lowercased(),
                       let user = url?.user(percentEncoded: false), let password = url?.password(percentEncoded: false) {
                        return completionHandler(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
                    }
                    if agentDialogHandler?("\(space.host) asks for a sign-in: open https://user:password@\(space.host)/ to give it") == true {
                        return completionHandler(.performDefaultHandling, nil)
                    }
                }
                let prompt = { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            HTTPAuthChallengeHandler().resolve(
                                challenge, in: self?.webView.window, usesKeychain: self?.isPrivateBrowsing == false,
                                completion: completionHandler
                            )
                        }
                    }
                }
                // Private spaces never use an extension's proxy.
                guard space.isProxy(), !isPrivateBrowsing, let delegate else { return prompt() }
                delegate.tab(self, authenticateProxy: challenge) { answer in
                    if let answer { completionHandler(answer.0, answer.1) } else { prompt() }
                }
            } else if method == NSURLAuthenticationMethodClientCertificate, !isAgentControlled {
                ClientCertificateChallengeHandler.resolve(challenge, in: webView.window, completion: completionHandler)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    // WebKit calls this on the main thread; answer synchronously instead of paying the async
    // delegate variant's runloop hops per response.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let isMainFrame = navigationResponse.isForMainFrame
            if isMainFrame {
                if navigationResponse.response is HTTPURLResponse {
                    StartupMetrics.markOnce("firstContentResponseReceived")
                }
                StartupMetrics.markOnce("firstContentResponsePolicyDecided")
            }
            let decision = Self.policyForNavigationResponse(
                navigationResponse.response,
                isMainFrame: isMainFrame,
                canShowMIMEType: navigationResponse.canShowMIMEType
            )
            if decision == .download, !isPrivateBrowsing {
                Self.logger.info("""
                    download from navigation response url=\(navigationResponse.response.url?.absoluteString ?? "nil", privacy: .private) \
                    mime=\(navigationResponse.response.mimeType ?? "nil", privacy: .public) \
                    mainFrame=\(isMainFrame, privacy: .public)
                    """)
            }
            decisionHandler(decision)
        }
    }

    // WebKit checks `download.delegate` synchronously on return; setting it a runloop turn later leaves
    // no decideDestination handler and WebKit cancels the download silently.
    nonisolated func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated { delegate?.tab(self, didStartDownload: download) }
    }

    nonisolated func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated { delegate?.tab(self, didStartDownload: download) }
    }
}

// MARK: - WKUIDelegate

extension WKWebViewTab: WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            // Only the shim's own blank open from the main frame: never a link or another frame's popup. The popup
            // blocker is off meanwhile, so any other popup is refused.
            if let size = pendingDocumentPiPSize {
                let url = navigationAction.request.url
                guard navigationAction.sourceFrame.isMainFrame,
                      url == nil || url?.absoluteString.isEmpty == true || url?.absoluteString == "about:blank" else { return nil }
                cancelPendingDocumentPiP()
                return documentPiPWebViewProvider?(configuration, size)
            }
            // Any frame within the click's own task; only the main frame later, while this page has the activation.
            let isActivated = Self.activatedWebView === webView
                && ProcessInfo.processInfo.systemUptime - Self.activationTime < Self.popupActivationWindow
            guard WebViewPrivateAccessors(navigationAction).bool("_isUserInitiated") == true
                    || navigationAction.sourceFrame.isMainFrame && isActivated else { return nil }
            // An agent's popups open as tabs of its folder: a popup window would come over the user's.
            if !isAgentControlled, let provider = popupWebViewProvider, let popup = provider(configuration, navigationAction, windowFeatures) {
                return popup
            }
            delegate?.tab(self, didCreateNewTab: navigationAction.request.url, inBackground: Self.opensNewTabInBackground(navigationAction, after: nil))
            return nil
        }
    }

    nonisolated func webViewDidClose(_ webView: WKWebView) {
        onMain { tab in
            tab.pageRequestedClose = true
            tab.delegate?.tabDidRequestClose(tab)
        }
    }

    // AVKit's return button needs the web view visible before WebKit can restore the video inline, so a
    // backgrounded tab must be foregrounded first or the click does nothing.
    @objc(_webViewFullscreenMayReturnToInline:)
    nonisolated func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        onMain { $0.delegate?.tabRequestsForeground($0) }
    }

    // Gives both the proposed menu and the clicked element. The public-looking
    // `webView:willShowContextMenu:` is not a real WebKit selector and never fires.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    nonisolated func webView(
        _ webView: WKWebView,
        getContextMenuFromProposedMenu menu: NSMenu,
        forElement element: NSObject?,
        userInfo: Any?,
        completionHandler: @escaping @MainActor @Sendable (NSMenu?) -> Void
    ) {
        nonisolated(unsafe) let menu = menu
        nonisolated(unsafe) let element = element
        MainActor.assumeIsolated {
            contextMenuBuilder.build(menu, linkURL: ContextMenuBuilder.linkURL(from: element), imageURL: ContextMenuBuilder.imageURL(from: element) ?? ContextMenuBuilder.mediaURL(from: element), extensionItems: extensionContextMenuItemsProvider?() ?? [], offersNewWindow: !(delegate?.prefersSingleWindow ?? false))
            completionHandler(menu)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let typeName: String
        switch type {
        case .camera: typeName = "camera"
        case .microphone: typeName = "microphone"
        case .cameraAndMicrophone: typeName = "camera and microphone"
        @unknown default: typeName = "media"
        }
        handlePermission(typeName, for: origin, decisionHandler: decisionHandler)
    }

    // WebKit calls this on the main thread; the delegate answers a stored decision synchronously
    // and only prompts asynchronously, so there is no runloop hop to pay here.
    nonisolated private func handlePermission(
        _ type: String,
        for origin: WKSecurityOrigin,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        MainActor.assumeIsolated {
            if agentDialogHandler?("\(type) permission for \(origin.permissionOriginKey) denied: agent tabs never ask the user") == true {
                return decisionHandler(.deny)
            }
            // WebKit crashes on a decision handler released uncalled.
            guard let delegate else { return decisionHandler(.deny) }
            delegate.tab(self, requestPermission: type, forOrigin: origin.permissionOriginKey) { granted in
                decisionHandler(granted ? .grant : .deny)
            }
        }
    }

    // getDisplayMedia() deliberately has no display-capture delegate: without the SPI WebKit shows the self-consenting system
    // SCContentSharingPicker (no Screen Recording permission); the SPI would force our own window-or-screen pre-prompt.

    // beforeunload: WebKit asks before leaving a page whose onbeforeunload handler requests it.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    nonisolated func webView(
        _ webView: WKWebView,
        runBeforeUnloadConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        onMain { tab in
            // Like browsers, a page nobody looks at leaves without asking: the prompt would wait unseen.
            if tab.isLeaving || tab.agentDialogHandler?("beforeunload: left the page") == true || !tab.isOnScreen { return completionHandler(true) }
            JSDialogPresenter.runBeforeUnload(in: webView, completion: completionHandler)
        }
    }

    // Pointer Lock (games / immersive apps): grant the request; WebKit handles the cursor mechanics.
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    nonisolated func webViewDidRequestPointerLock(
        _ webView: WKWebView,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        DispatchQueue.main.async { completionHandler(true) }
    }

    @objc(_webViewDidLosePointerLock:)
    nonisolated func webViewDidLosePointerLock(_ webView: WKWebView) {}

    // Tab-key focus traversal out of the web view (accessibility). _WKFocusDirection: 0 = backward.
    @objc(_webView:takeFocus:)
    nonisolated func webView(_ webView: WKWebView, takeFocus direction: Int) {
        DispatchQueue.main.async {
            if direction == 0 { webView.window?.selectPreviousKeyView(webView) } else { webView.window?.selectNextKeyView(webView) }
        }
    }

    // Storage Access API: a cross-site embed asks to use its own cookies under the current site.
    @objc(_webView:requestStorageAccessPanelForDomain:underCurrentDomain:completionHandler:)
    nonisolated func webView(
        _ webView: WKWebView,
        requestStorageAccessPanelForDomain requestingDomain: String,
        underCurrentDomain currentDomain: String,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        JSDialogPresenter.runStorageAccessPrompt(in: webView, requestingDomain: requestingDomain, currentDomain: currentDomain, completion: completionHandler)
    }

    // A service worker (e.g. a push-notification click) asks to bring its tab to the foreground.
    @objc(_focusWebViewFromServiceWorker:)
    nonisolated func focusWebViewFromServiceWorker(_ webView: WKWebView) {
        onMain { $0.delegate?.tabRequestsForeground($0) }
    }

    // `window.focus()` from the page itself (WKUIDelegatePrivate): WebKit drops the call without this
    // hook. WebCore already gates it on a user gesture or an opener relationship, so honouring it
    // cannot become a way for a background tab to steal the foreground.
    @objc(_focusWebView:)
    nonisolated func focusWebView(_ webView: WKWebView) {
        onMain { $0.delegate?.tabRequestsForeground($0) }
    }

    // `window.print()` (WKUIDelegatePrivate): without this hook the page's print request never reaches
    // the app. The frame handle is ignored: printOperation covers the whole page, exactly like the
    // app's own Cmd+P.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    nonisolated func webView(
        _ webView: WKWebView,
        printFrame frame: Any,
        pdfFirstPageSize: CGSize,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        onMain { $0.printPage(in: webView.window, completion: completionHandler) }
    }

    // SpeechRecognition (WKUIDelegatePrivate): WebKit denies outright without this hook. Recognition
    // captures the microphone, so it rides the site's microphone decision instead of asking twice.
    @objc(_webView:requestSpeechRecognitionPermissionForOrigin:decisionHandler:)
    nonisolated func webView(
        _ webView: WKWebView,
        requestSpeechRecognitionPermissionForOrigin origin: WKSecurityOrigin,
        decisionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        handlePermission("microphone", for: origin) { decisionHandler($0 == .grant) }
    }

    // Hovered link for the status-bar readout (WKUIDelegatePrivate). WebKit hit-tests the element
    // under the pointer for its own needs, so this rides an existing computation instead of a
    // mouseover listener in every frame of every page.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    nonisolated func webView(
        _ webView: WKWebView,
        mouseDidMoveOverElement element: Any?,
        withFlags flags: UInt,
        userInfo: Any?
    ) {
        let link = element as? NSObject
        let url = link?.responds(to: NSSelectorFromString("absoluteLinkURL")) == true
            ? link?.value(forKey: "absoluteLinkURL") as? URL
            : nil
        // A `javascript:` href is a script handler, not a destination: nothing to show.
        let href = url?.scheme?.lowercased() == "javascript" ? nil : url?.absoluteString
        onMain { $0.delegate?.tab($0, didHoverLink: href) }
    }

    // Permissions API (navigator.permissions.query): report the stored decision WITHOUT prompting.
    @objc(_webView:queryPermission:forOrigin:completionHandler:)
    nonisolated func webView(
        _ webView: WKWebView,
        queryPermission name: String,
        forOrigin origin: WKSecurityOrigin,
        completionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        onMain { tab in
            let type = Self.permissionQueryType(name)
            let stored = tab.delegate?.tab(tab, storedPermissionDecisionFor: type, origin: origin.permissionOriginKey)
            completionHandler(stored == true ? .grant : stored == false ? .deny : .prompt)
        }
    }

    private static func permissionQueryType(_ name: String) -> String {
        name.lowercased() == "geolocation" ? "location" : name.lowercased()
    }

    /// Window frame (WKUIDelegatePrivate): unanswered, pages read a zero `outerWidth` and sites deriving zoom from it render at half
    /// resolution. The web process caches it until the window moves, so a detached or pre-window load falls back to any window or screen.
    /// It spans only the page's width: sites read `outerWidth - innerWidth` over 160 as open devtools, which the sidebar would pass.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, getWindowFrameWith completionHandler: @escaping (CGRect) -> Void) {
        let window = webView.window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        guard var frame = window?.frame else { return completionHandler(NSScreen.main?.visibleFrame ?? .zero) }
        if webView.bounds.width > 0 {
            if let window = webView.window { frame.origin.x = window.convertToScreen(webView.convert(webView.bounds, to: nil)).minX }
            frame.size.width = webView.bounds.width
        }
        completionHandler(frame)
    }

    // Printed-page header/footer (WKUIDelegatePrivate): the page title and source URL.
    @objc(_webViewHeaderHeight:)
    nonisolated func webViewHeaderHeight(_ webView: WKWebView) -> CGFloat { Self.printEdgeHeight }
    @objc(_webViewFooterHeight:)
    nonisolated func webViewFooterHeight(_ webView: WKWebView) -> CGFloat { Self.printEdgeHeight }

    @objc(_webView:drawHeaderInRect:forPageWithTitle:URL:)
    nonisolated func webView(_ webView: WKWebView, drawHeaderInRect rect: CGRect, forPageWithTitle title: String, url: URL) {
        Self.drawPrintEdge(in: rect, leading: title, trailing: Self.printDateString)
    }
    @objc(_webView:drawFooterInRect:forPageWithTitle:URL:)
    nonisolated func webView(_ webView: WKWebView, drawFooterInRect rect: CGRect, forPageWithTitle title: String, url: URL) {
        Self.drawPrintEdge(in: rect, leading: url.absoluteString, trailing: nil)
    }

    nonisolated private static let printEdgeHeight: CGFloat = 18
    nonisolated private static var printDateString: String {
        DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
    }

    // Called by WebKit on the main thread during the (modal) print operation.
    nonisolated private static func drawPrintEdge(in rect: CGRect, leading: String, trailing: String?) {
        MainActor.assumeIsolated {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
            let pad: CGFloat = 6
            let trailingWidth: CGFloat = trailing == nil ? 0 : 150
            let leadingStyle = NSMutableParagraphStyle(); leadingStyle.lineBreakMode = .byTruncatingMiddle
            let leadingRect = CGRect(x: rect.minX + pad, y: rect.minY + 4, width: max(0, rect.width - 2 * pad - trailingWidth), height: rect.height - 4)
            NSString(string: leading).draw(in: leadingRect, withAttributes: attrs.merging([.paragraphStyle: leadingStyle]) { _, new in new })
            if let trailing {
                let trailingStyle = NSMutableParagraphStyle(); trailingStyle.lineBreakMode = .byTruncatingTail; trailingStyle.alignment = .right
                let trailingRect = CGRect(x: rect.maxX - pad - trailingWidth, y: rect.minY + 4, width: trailingWidth, height: rect.height - 4)
                NSString(string: trailing).draw(in: trailingRect, withAttributes: attrs.merging([.paragraphStyle: trailingStyle]) { _, new in new })
            }
        }
    }

    // Blob/data save (WKUIDelegatePrivate): a page hands us bytes to write (canvas export, generated file).
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    nonisolated func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data,
        suggestedFilename: String,
        mimeType: String,
        originatingURL url: URL
    ) {
        onMain { $0.delegate?.tab($0, saveData: data, suggestedFilename: suggestedFilename, mimeType: mimeType, originatingURL: url) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        if agentDialogHandler?("alert(\(message)) dismissed") == true { completionHandler(); return }
        runWhenShown { $0 ? JSDialogPresenter.runAlert(in: webView, message: message, completion: completionHandler) : completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        if agentDialogHandler?("confirm(\(message)) accepted") == true { completionHandler(true); return }
        runWhenShown { $0 ? JSDialogPresenter.runConfirm(in: webView, message: message, completion: completionHandler) : completionHandler(false) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        if agentDialogHandler?("prompt(\(prompt)) answered with its default") == true { completionHandler(defaultText ?? ""); return }
        runWhenShown { show in
            guard show else { return completionHandler(nil) }
            JSDialogPresenter.runPrompt(in: webView, prompt: prompt, defaultText: defaultText, completion: completionHandler)
        }
    }

    /// In a window and not hidden: a background tab, a tab of another space or a hidden peek is not.
    private var isOnScreen: Bool { webView.window != nil && !webView.isHiddenOrHasHiddenAncestor }

    /// Runs `dialog` now when the tab is on screen; otherwise holds it until the tab is shown, and
    /// marks the tab as waiting for the user meanwhile.
    private func runWhenShown(_ dialog: @escaping @MainActor (Bool) -> Void) {
        guard !isOnScreen else { return dialog(true) }
        runQueuedDialog(presenting: false)
        queuedDialog = dialog
        delegate?.tab(self, didUpdateAwaitingDialog: true)
    }

    /// Presents the dialog the page raised while the tab was off screen, once it shows, or dismisses it.
    func runQueuedDialog(presenting: Bool) {
        guard let dialog = queuedDialog else { return }
        queuedDialog = nil
        delegate?.tab(self, didUpdateAwaitingDialog: false)
        dialog(presenting)
    }

    nonisolated func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        onMain { tab in
            if let uploads = tab.pendingAgentUploads {
                tab.pendingAgentUploads = nil
                completionHandler(uploads)
            } else {
                JSDialogPresenter.runOpenPanel(in: webView, parameters: parameters, completion: completionHandler)
            }
        }
    }
}

// MARK: - PrintCompletionProxy

/// NSPrintOperation reports the end of its panel through a target/selector pair, so a page-initiated
/// print parks the block that resumes the page here until the panel closes.
@MainActor
final class PrintCompletionProxy: NSObject {
    private let completion: () -> Void

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    @objc func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        completion()
    }
}
