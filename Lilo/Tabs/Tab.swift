import Foundation

/// Represents a browser tab with all its metadata.
struct Tab: Sendable, Equatable {
    static let placeholderTitle = "New Tab"

    enum Kind: String, Sendable {
        /// `changes` shows the diff of the repository at `cwd`; `agent` is a conversation with an ACP agent,
        /// the first tab of its own folder, whose other tabs are the pages the agent opened.
        case web, terminal, changes, agent
    }

    let id: UUID
    var url: URL?
    var title: String
    var faviconDataURL: String?
    var faviconDominantColor: String?
    /// The solid color along the page's top edge, else hex stops read off that edge, else its theme-color.
    var pageColor: String?
    var isLoading: Bool = false
    var estimatedProgress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isPinned: Bool
    var isBookmarked: Bool
    var isClosed: Bool
    var homeURL: URL?
    var homeTitle: String?
    var homeFaviconDataURL: String?
    var homeFaviconDominantColor: String?
    /// Pinned and bookmarked tabs: the user's name for the tab, shown in the sidebar and previews; the window title, history and
    /// extensions keep `title`.
    var customTitle: String?
    var isAudioPlaying: Bool = false
    var lastAudioStoppedAt: Date?
    /// Runtime only: paused from the sidebar media card, which keeps it there ready to play again.
    var pausedFromCardAt: Date?
    var isMuted: Bool = false
    var hasUnsavedFormData: Bool = false
    var isMicrophoneActive: Bool = false
    var isMicrophoneMuted: Bool = false
    var isCameraActive: Bool = false
    var isScreenSharing: Bool = false
    /// Runtime only: the page is in a call even without capture: it offers a Media Session hangup or holds a live
    /// WebRTC connection (Meet's companion mode).
    var isInCall = false
    /// Runtime only: a video of the page is in the system PiP window, so lifecycle never freezes or discards it.
    var isInPictureInPicture = false
    var hasPopup: Bool = false
    /// Runtime only: an agent drives this tab, so lifecycle never freezes or discards it.
    var isAgentControlled = false
    /// When capture (mic/camera/screen) last transitioned from on to off. Drives a retention grace
    /// period that mirrors `lastAudioStoppedAt`, so a tab still in a call survives WebKit's transient
    /// `.none` capture-state blips (mute/unmute, device switch, track renegotiation) without being trimmed.
    var lastCaptureStoppedAt: Date?
    var lastActiveAt: Date?
    var hasNavigationError: Bool = false
    var navigationErrorCode: Int = 0
    var navigationErrorDomain: String = ""
    var navigationErrorDescription: String = ""
    var navigationErrorURL: String = ""
    var navigationErrorUsesHSTS = false
    var isNotSecure = false
    var groupId: UUID?
    var spaceId: UUID?
    var windowId: UUID?
    var kind = Kind.web
    /// Terminal tabs: the shell's working directory, where a restored tab starts again. Agent tabs: the project.
    var cwd: String?
    /// Agent tabs: the agent's id in the ACP registry, and its session, resumed with `session/load`.
    var agentId: String?
    var agentSessionId: String?
    /// Terminal tabs: the last interactive or long command, typed at a restored tab's first prompt.
    var resumeCommand: String?
    /// Terminal tabs, runtime only: the branch checked out in `cwd`, empty outside a repository.
    var gitBranch = ""
    /// Terminal tabs, runtime only: lines added and removed in that repository against HEAD.
    var diffAdded = 0
    var diffRemoved = 0
    /// Terminal tabs, runtime only: a `TerminalSession.State` raw value, empty before the shell runs.
    var terminalState = ""
    /// Terminal tabs, runtime only: the running or last command, and how it went.
    var terminalCommand = ""
    var terminalStartedAt: Date?
    var terminalExitCode: Int32 = 0
    var terminalDuration: TimeInterval = 0
    var hasUnreadOutput = false
    /// Web tabs, runtime only: the page posted a notification while the tab was not shown.
    var hasUnreadNotification = false
    /// Runtime only: when the terminal's running program, or a page dialog held until the tab shows, started waiting for an answer.
    var awaitingInputSince: Date?

    init(
        id: UUID = UUID(), url: URL? = nil, title: String = "New Tab",
        faviconDataURL: String? = nil, faviconDominantColor: String? = nil,
        isPinned: Bool = false, isBookmarked: Bool = false, isClosed: Bool = false,
        homeURL: URL? = nil, homeTitle: String? = nil,
        homeFaviconDataURL: String? = nil, homeFaviconDominantColor: String? = nil,
        groupId: UUID? = nil, spaceId: UUID? = nil, windowId: UUID? = nil,
        kind: Kind = .web, cwd: String? = nil, resumeCommand: String? = nil, customTitle: String? = nil,
        agentId: String? = nil, agentSessionId: String? = nil
    ) {
        self.id = id; self.url = url; self.title = title
        self.faviconDataURL = faviconDataURL; self.faviconDominantColor = faviconDominantColor
        self.isPinned = isPinned; self.isBookmarked = isBookmarked; self.isClosed = isClosed
        self.homeURL = homeURL
        self.homeTitle = homeTitle
        self.homeFaviconDataURL = homeFaviconDataURL
        self.homeFaviconDominantColor = homeFaviconDominantColor
        self.groupId = groupId
        self.spaceId = spaceId; self.windowId = windowId
        self.kind = kind; self.cwd = cwd; self.resumeCommand = resumeCommand
        self.customTitle = customTitle
        self.agentId = agentId; self.agentSessionId = agentSessionId
    }

    static func fallbackTitle(for url: URL?) -> String {
        guard let url else { return placeholderTitle }

        if let host = url.host, !host.isEmpty {
            let path = url.path == "/" ? "" : url.path
            let query = url.query.map { "?\($0)" } ?? ""
            let fragment = url.fragment.map { "#\($0)" } ?? ""
            let display = host + path + query + fragment
            if !display.isEmpty {
                return display
            }
        }

        let absoluteString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return absoluteString.isEmpty ? placeholderTitle : absoluteString
    }

    func matchesHomeURL(_ currentURL: URL?) -> Bool {
        guard let homeURL, let currentURL else { return false }
        // Fast path: identical strings need no normalization, the common "tab sitting at its
        // home URL" case, hit on every navigation/favicon event for pinned/bookmarked tabs.
        if homeURL.absoluteString == currentURL.absoluteString { return true }
        // Otherwise normalize equivalent URL forms (e.g. trailing slash/default port) while still
        // distinguishing different paths/query for home matching.
        return Self.homeURLMatchKey(for: homeURL) == Self.homeURLMatchKey(for: currentURL)
    }

    private static func homeURLMatchKey(for url: URL?) -> String? {
        guard let url else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let rawHost = components.host else {
            let absolute = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            return absolute.isEmpty ? nil : absolute
        }

        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        let port = components.port ?? defaultPort(for: scheme)
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery ?? ""
        return "\(scheme)://\(host):\(port ?? -1)\(path)?\(query)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    /// Serializable dictionary for bridge communication.
    /// Built via exhaustive switch over `TabBridgeField.allCases`, adding a schema field
    /// is a compile error until Swift handles it here.
    var bridgeData: [String: Any] { bridgeData(excluding: []) }

    func bridgeData(excluding excluded: Set<TabBridgeField>, omittingDefaults: Bool = false) -> [String: Any] {
        var data = [String: Any](minimumCapacity: TabBridgeField.allCases.count)
        // With omittingDefaults, the fields at false, 0 or "" stay out (see snapshotData).
        func put(_ field: TabBridgeField, _ value: Bool) { if value || !omittingDefaults { data[field.rawValue] = value } }
        func put(_ field: TabBridgeField, _ value: Double) { if value != 0 || !omittingDefaults { data[field.rawValue] = value } }
        func put(_ field: TabBridgeField, _ value: Int) { if value != 0 || !omittingDefaults { data[field.rawValue] = value } }
        func put(_ field: TabBridgeField, _ value: String) { if !value.isEmpty || !omittingDefaults { data[field.rawValue] = value } }
        for field in TabBridgeField.allCases {
            if excluded.contains(field) { continue }
            switch field {
            case .id:
                data[field.rawValue] = id.uuidString
            case .url:
                data[field.rawValue] = url?.absoluteString ?? ""
            case .title:
                data[field.rawValue] = title
            case .customTitle:
                put(field, customTitle ?? "")
            case .homeTitle:
                if isPinned || isBookmarked, let homeURL, url != nil, !matchesHomeURL(url) {
                    put(field, homeTitle.flatMap { $0.isEmpty ? nil : $0 } ?? Tab.fallbackTitle(for: homeURL))
                } else {
                    put(field, "")
                }
            case .isLoading:
                put(field, isLoading)
            case .progress:
                put(field, estimatedProgress)
            case .canGoBack:
                put(field, canGoBack)
            case .canGoForward:
                put(field, canGoForward)
            case .isPinned:
                put(field, isPinned)
            case .isBookmarked:
                put(field, isBookmarked)
            case .isClosed:
                put(field, isClosed)
            case .isAudioPlaying:
                put(field, isAudioPlaying)
            case .isMuted:
                put(field, isMuted)
            case .isMicrophoneActive:
                put(field, isMicrophoneActive)
            case .isMicrophoneMuted:
                put(field, isMicrophoneMuted)
            case .isCameraActive:
                put(field, isCameraActive)
            case .isScreenSharing:
                put(field, isScreenSharing)
            case .hasPopup:
                put(field, hasPopup)
            case .hasNavigationError:
                put(field, hasNavigationError)
            case .navigationErrorCode:
                put(field, navigationErrorCode)
            case .navigationErrorDomain:
                put(field, navigationErrorDomain)
            case .navigationErrorDescription:
                put(field, navigationErrorDescription)
            case .navigationErrorURL:
                put(field, navigationErrorURL)
            case .navigationErrorUsesHSTS:
                put(field, navigationErrorUsesHSTS)
            case .isNotSecure:
                put(field, isNotSecure)
            case .faviconDataURL:
                data[field.rawValue] = faviconDataURL ?? ""
            case .faviconDominantColor:
                // Empty, not omitted, when nil: the UI merges patches key by key, so an omitted key
                // would keep the previous site's color.
                data[field.rawValue] = faviconDominantColor ?? ""
            case .pageColor:
                put(field, pageColor ?? "")
            case .groupId:
                if let groupId { put(field, groupId.uuidString) }
            case .spaceId:
                if let spaceId { put(field, spaceId.uuidString) }
            case .kind:
                put(field, kind.rawValue)
            case .cwd:
                put(field, cwd ?? "")
            case .agentId:
                put(field, agentId ?? "")
            case .gitBranch:
                put(field, gitBranch)
            case .diffAdded:
                put(field, Double(diffAdded))
            case .diffRemoved:
                put(field, Double(diffRemoved))
            case .terminalState:
                put(field, terminalState)
            case .terminalCommand:
                put(field, terminalCommand)
            case .terminalStartedAt:
                put(field, (terminalStartedAt?.timeIntervalSince1970 ?? 0) * 1000)
            case .terminalExitCode:
                put(field, Double(terminalExitCode))
            case .terminalDuration:
                put(field, terminalDuration)
            case .hasUnreadOutput:
                put(field, hasUnreadOutput)
            case .hasUnreadNotification:
                put(field, hasUnreadNotification)
            case .awaitingInputSince:
                put(field, (awaitingInputSince?.timeIntervalSince1970 ?? 0) * 1000)
            }
        }
        return data
    }

    /// A whole snapshot for the chrome, which fills a missing field back in with its default when it coerces one: the fields still at
    /// false, 0 or "" stay home, most of a tab. Never for a runtime patch, where a missing field means unchanged; and the favicon
    /// fields always go, since a snapshot without one keeps the favicon the chrome holds.
    func snapshotData(excluding excluded: Set<TabBridgeField> = []) -> [String: Any] {
        bridgeData(excluding: excluded, omittingDefaults: true)
    }

    /// Runtime-patch payload: `bridgeData` minus the heavy favicon fields, which never change on a
    /// progress/loading/nav-flag tick. The UI merges these onto the existing tab, preserving the
    /// favicon it already holds. Full snapshots and `sidebarChanged` upserts still carry the favicon.
    var runtimePatchData: [String: Any] { bridgeData(excluding: TabBridgeField.runtimeExcluded) }
}

private struct TabRuntimeState: Equatable, Sendable {
    let isLoading: Bool; let estimatedProgress: Double
    let canGoBack: Bool; let canGoForward: Bool
    let isAudioPlaying: Bool; let lastAudioStoppedAt: Date?; let pausedFromCardAt: Date?; let isMuted: Bool
    let isMicrophoneActive: Bool; let isMicrophoneMuted: Bool
    let isCameraActive: Bool; let isScreenSharing: Bool; let lastCaptureStoppedAt: Date?; let lastActiveAt: Date?
    let isInCall: Bool
    let isInPictureInPicture: Bool
    let hasPopup: Bool
    let isAgentControlled: Bool
    let hasNavigationError: Bool; let navigationErrorCode: Int
    let navigationErrorDomain: String; let navigationErrorDescription: String; let navigationErrorURL: String
    let navigationErrorUsesHSTS: Bool
    let isNotSecure: Bool
    let windowId: UUID?
    let hasUnsavedFormData: Bool
    let gitBranch: String
    let diffAdded: Int
    let diffRemoved: Int
    let terminalState: String
    let terminalCommand: String
    let terminalStartedAt: Date?
    let terminalExitCode: Int32
    let terminalDuration: TimeInterval
    let hasUnreadOutput: Bool
    let hasUnreadNotification: Bool
    let awaitingInputSince: Date?

    init(_ tab: Tab) {
        isLoading = tab.isLoading; estimatedProgress = tab.estimatedProgress
        canGoBack = tab.canGoBack; canGoForward = tab.canGoForward
        isAudioPlaying = tab.isAudioPlaying; lastAudioStoppedAt = tab.lastAudioStoppedAt; pausedFromCardAt = tab.pausedFromCardAt; isMuted = tab.isMuted
        isMicrophoneActive = tab.isMicrophoneActive; isMicrophoneMuted = tab.isMicrophoneMuted
        isCameraActive = tab.isCameraActive; isScreenSharing = tab.isScreenSharing; lastCaptureStoppedAt = tab.lastCaptureStoppedAt; lastActiveAt = tab.lastActiveAt
        isInCall = tab.isInCall
        isInPictureInPicture = tab.isInPictureInPicture
        hasPopup = tab.hasPopup
        isAgentControlled = tab.isAgentControlled
        hasNavigationError = tab.hasNavigationError; navigationErrorCode = tab.navigationErrorCode
        navigationErrorDomain = tab.navigationErrorDomain; navigationErrorDescription = tab.navigationErrorDescription; navigationErrorURL = tab.navigationErrorURL
        navigationErrorUsesHSTS = tab.navigationErrorUsesHSTS
        isNotSecure = tab.isNotSecure
        windowId = tab.windowId
        hasUnsavedFormData = tab.hasUnsavedFormData
        gitBranch = tab.gitBranch
        diffAdded = tab.diffAdded
        diffRemoved = tab.diffRemoved
        terminalState = tab.terminalState
        terminalCommand = tab.terminalCommand
        terminalStartedAt = tab.terminalStartedAt
        terminalExitCode = tab.terminalExitCode
        terminalDuration = tab.terminalDuration
        hasUnreadOutput = tab.hasUnreadOutput
        hasUnreadNotification = tab.hasUnreadNotification
        awaitingInputSince = tab.awaitingInputSince
    }

    func applied(to tab: Tab) -> Tab {
        var tab = tab
        tab.isLoading = isLoading; tab.estimatedProgress = estimatedProgress
        tab.canGoBack = canGoBack; tab.canGoForward = canGoForward
        tab.isAudioPlaying = isAudioPlaying; tab.lastAudioStoppedAt = lastAudioStoppedAt; tab.pausedFromCardAt = pausedFromCardAt; tab.isMuted = isMuted
        tab.isMicrophoneActive = isMicrophoneActive; tab.isMicrophoneMuted = isMicrophoneMuted
        tab.isCameraActive = isCameraActive; tab.isScreenSharing = isScreenSharing; tab.lastCaptureStoppedAt = lastCaptureStoppedAt; tab.lastActiveAt = lastActiveAt
        tab.isInCall = isInCall
        tab.isInPictureInPicture = isInPictureInPicture
        tab.hasPopup = hasPopup
        tab.isAgentControlled = isAgentControlled
        tab.hasNavigationError = hasNavigationError; tab.navigationErrorCode = navigationErrorCode
        tab.navigationErrorDomain = navigationErrorDomain; tab.navigationErrorDescription = navigationErrorDescription; tab.navigationErrorURL = navigationErrorURL
        tab.navigationErrorUsesHSTS = navigationErrorUsesHSTS
        tab.isNotSecure = isNotSecure
        tab.windowId = windowId
        tab.hasUnsavedFormData = hasUnsavedFormData
        tab.gitBranch = gitBranch
        tab.diffAdded = diffAdded
        tab.diffRemoved = diffRemoved
        tab.terminalState = terminalState
        tab.terminalCommand = terminalCommand
        tab.terminalStartedAt = terminalStartedAt
        tab.terminalExitCode = terminalExitCode
        tab.terminalDuration = terminalDuration
        tab.hasUnreadOutput = hasUnreadOutput
        tab.hasUnreadNotification = hasUnreadNotification
        tab.awaitingInputSince = awaitingInputSince
        return tab
    }
}

@MainActor
final class RuntimeOverlayStore {
    private var states: [UUID: TabRuntimeState] = [:]

    /// Monotonically increasing on every mutation of the overlay. A cheap dirty signal: callers that
    /// re-derive state from the overlay (e.g. syncActiveBrowserState) can early-return when this is
    /// unchanged since their last read. It only goes up, never resets, so it can never alias.
    private(set) var version: UInt64 = 0

    func setRuntimeState(from tab: Tab) {
        let state = TabRuntimeState(tab)
        guard states[tab.id] != state else { return }
        states[tab.id] = state
        version &+= 1
    }

    func removeRuntimeState(for id: UUID) {
        guard states.removeValue(forKey: id) != nil else { return }
        version &+= 1
    }

    /// A discarded engine takes its runtime state along; what the user or an agent set on the tab
    /// (mute, agent control, a pause from the media card) stays for the engine that replaces it.
    func discardRuntimeState(for id: UUID) {
        guard let state = states[id] else { return }
        var kept = Tab(id: id)
        kept.isMuted = state.isMuted
        kept.isAgentControlled = state.isAgentControlled
        kept.pausedFromCardAt = state.pausedFromCardAt
        let next = TabRuntimeState(kept)
        guard next != state else { return }
        states[id] = next == TabRuntimeState(Tab(id: id)) ? nil : next
        version &+= 1
    }

    func applied(to tab: Tab) -> Tab {
        states[tab.id]?.applied(to: tab) ?? tab
    }

    func retainRuntimeStates(validTabIds: Set<UUID>) {
        let countBefore = states.count
        states = states.filter { validTabIds.contains($0.key) }
        if states.count != countBefore { version &+= 1 }
    }
}
