import Foundation
import GRDB

/// Simple key-value settings store backed by the global database. Reads are served from an
/// in-memory mirror loaded once at init (accessors sit on hot paths: per-navigation and
/// per-tab-activation); writes queue on the pool's writer.
@MainActor
final class SettingsStore {
    private let dbPool: DatabasePool
    private var cache: [String: String]
    /// Set when the initial load failed: every accessor then serves defaults, and the caller must
    /// surface the degradation instead of letting it pass as a fresh install.
    private(set) var initialLoadError: Error?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        do {
            cache = try dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT key, value FROM settings")
                    .reduce(into: [:]) { $0[$1["key"]] = $1["value"] }
            }
        } catch {
            cache = [:]
            initialLoadError = error
        }
    }

    func get(_ key: String) -> String? {
        cache[key]
    }

    /// The cache answers at once; the row lands on the writer queue, ahead of any later write
    /// (the shutdown checkpoint included).
    func set(_ key: String, value: String) {
        cache[key] = value
        dbPool.asyncWrite({ db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", arguments: [key, value])
        }, completion: { _, result in
            loggingPersistenceError("settings.set[\(key)]") { try result.get() }
        })
    }

    func remove(_ key: String) {
        cache.removeValue(forKey: key)
        dbPool.asyncWrite({ db in
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }, completion: { _, result in
            loggingPersistenceError("settings.remove[\(key)]") { try result.get() }
        })
    }

    func allSettings() -> [String: String] {
        cache
    }

    // MARK: - Typed Helpers

    var searchEngine: String { self.get("searchEngine") ?? "google" }

    var askDownloadLocation: Bool {
        get { get("askDownloadLocation") == "true" }
        set { set("askDownloadLocation", value: newValue ? "true" : "false") }
    }

    var searchSuggestions: Bool { (get("searchSuggestions") ?? "true") == "true" }

    var lifecyclePreset: LifecyclePreset {
        get { LifecyclePreset(rawValue: get("lifecyclePreset") ?? "") ?? .balanced }
        set { set("lifecyclePreset", value: newValue.rawValue) }
    }

    var defaultZoom: Double {
        get { Double(get("defaultZoom") ?? "1.0") ?? 1.0 }
        set { set("defaultZoom", value: String(newValue)) }
    }

    var sidebarWidth: Double {
        get { Double(get("sidebarWidth") ?? "260") ?? 260 }
        set { set("sidebarWidth", value: String(newValue)) }
    }

    /// One Agents space per profile agents work in, comma-separated.
    var agentsSpaceIds: [UUID] {
        (get(AgentControl.agentsSpaceKey) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    var sidebarVisible: Bool {
        get { (get("sidebarVisible") ?? "true") == "true" }
        set { set("sidebarVisible", value: newValue ? "true" : "false") }
    }

    var tabLayout: TabLayout {
        TabLayout(storedPosition: get("tabPosition"), storedAddress: get("addressPlacement"))
    }

    var windowBackgroundColor: String {
        get { get("windowBackgroundColor") ?? "" }
        set { set("windowBackgroundColor", value: newValue) }
    }

    var downloadsFolder: URL {
        get {
            get("downloadsFolder").map { URL(fileURLWithPath: $0) }
                ?? BuildIdentity.defaultDownloadsDirectory
        }
        set { set("downloadsFolder", value: newValue.path) }
    }

    var sessionCleanShutdown: Bool {
        get { (get("sessionCleanShutdown") ?? "true") == "true" }
        set { set("sessionCleanShutdown", value: newValue ? "true" : "false") }
    }

    /// "false" from a fresh install until the onboarding ends; "true" for an install that already has data.
    func resolveOnboarding(freshInstall: Bool) {
        guard get("onboardingCompleted") == nil else { return }
        // A failed load looks empty but is not a fresh install.
        set("onboardingCompleted", value: freshInstall && initialLoadError == nil ? "false" : "true")
    }

    var shouldShowOnboarding: Bool { self.get("onboardingCompleted") == "false" }

    var onboardingStep: Int {
        get { Int(get("onboardingStep") ?? "0") ?? 0 }
        set { set("onboardingStep", value: String(newValue)) }
    }

    func completeOnboarding() {
        set("onboardingCompleted", value: "true")
        remove("onboardingStep")
    }

    var didPromptDefaultBrowser: Bool {
        get { (get("didPromptDefaultBrowser") ?? "false") == "true" }
        set { set("didPromptDefaultBrowser", value: newValue ? "true" : "false") }
    }

    var contentBlockerEnabled: Bool { (get("contentBlockerEnabled") ?? "true") == "true" }

    /// The content blocker's list categories: all on but annoyances, regional lists by system language.
    var filterListSelection: FilterListService.ListSelection {
        FilterListService.ListSelection(
            trackers: get("blockerTrackers") != "false",
            cookieNotices: get("blockerCookieNotices") != "false",
            annoyances: get("blockerAnnoyances") == "true",
            badware: get("blockerBadware") != "false",
            regional: get("blockerRegional") != "false",
            languages: Locale.preferredLanguages
        )
    }

    /// Global Privacy Control / Do Not Track signals, injected via JS only.
    var sendGPC: Bool { (get("sendGPC") ?? "true") == "true" }

    /// WebKit's tracking prevention (ITP); on unless the user turns it off.
    var preventCrossSiteTracking: Bool { (get("preventCrossSiteTracking") ?? "true") == "true" }

    var minimumFontSize: CGFloat { CGFloat(Double(get("minimumFontSize") ?? "") ?? 0) }

    /// Upgrade http navigations to https, showing a warning page on failure.
    var httpsOnly: Bool { (get("httpsOnly") ?? "false") == "true" }

    /// Remove every persistent profile's cookies and website data when the app quits.
    var clearSiteDataOnQuit: Bool { (get("clearSiteDataOnQuit") ?? "false") == "true" }

    /// Auto-enter Picture-in-Picture when leaving a tab with active media (a call or playing video).
    var autoPictureInPicture: Bool { (get("autoPictureInPicture") ?? "true") == "true" }

    /// While Lilo is in front, a left call docks in the sidebar rather than the floating panel.
    var dockCallsInSidebar: Bool { (get("dockCallsInSidebar") ?? "true") == "true" }

    /// With headphones on, pages get the microphone without echo cancellation (see `MicrophoneBridge`).
    var fullBandMicrophone: Bool { (get("fullBandMicrophone") ?? "true") == "true" }

    /// Requests for a new window (New Window, a tab moved out, an extension window) open tabs in the
    /// current window instead.
    var singleWindow: Bool { self.get("singleWindow") == "true" }

    /// Cmd+Opt+N opens a Little window from any app.
    var littleWindowHotKey: Bool { self.get("littleWindowHotKey") != "false" }

    enum ExternalLinkDestination: Equatable {
        case currentSpace, littleWindow, space(UUID)
    }

    /// Where a link from another app opens: the first matching `externalLinkRules` entry (host, subdomain or contained text), else
    /// `externalLinkDefault`. A destination is "little" or a Space id; a missing Space falls back to the default, then the current one.
    func externalLinkDestination(for url: URL, spaceExists: (UUID) -> Bool) -> ExternalLinkDestination {
        func resolve(_ value: String?) -> ExternalLinkDestination? {
            if value == "little" { return .littleWindow }
            return value.flatMap(UUID.init(uuidString:)).flatMap { spaceExists($0) ? .space($0) : nil }
        }
        let fallback = resolve(get("externalLinkDefault")) ?? .currentSpace
        guard let json = get("externalLinkRules"),
              let rules = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] else { return fallback }
        let host = url.host()?.lowercased() ?? ""
        let text = url.absoluteString.lowercased()
        let rule = rules.first { rule in
            let pattern = (rule["pattern"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard !pattern.isEmpty else { return false }
            return rule["match"] == "host" ? host == pattern || host.hasSuffix("." + pattern) : text.contains(pattern)
        }
        return rule.map { resolve($0["destination"]) ?? fallback } ?? fallback
    }

    /// Terminal tabs can be opened; when off, existing ones stay until closed.
    var terminalEnabled: Bool { self.get("terminalEnabled") != "false" }

    /// Whether sites asking for `type` are refused without a prompt: the user's default for sites
    /// they have not answered. Camera and microphone share one default.
    func refusesPermissionRequests(_ type: String) -> Bool {
        let kind = ["camera", "microphone", "camera and microphone"].contains(type) ? "media" : type
        return get("permissionDefault.\(kind)") == "block"
    }

    /// Minutes of user inactivity before unlocked folders lock again.
    var folderAutoLockMinutes: Int { self.get("folderAutoLockMinutes").flatMap(Int.init) ?? 15 }

    var contentBlockerAllowlist: [String] {
        get {
            guard let json = get("contentBlockerAllowlist"),
                  let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return list
        }
        set {
            let json = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
            set("contentBlockerAllowlist", value: json)
        }
    }

    /// Domains whose requests are never blocked, whatever the page: the user's comma or space
    /// separated list, with entries that are not plain hostnames dropped.
    var blockerAllowlist: BlockerAllowlist {
        let domains = (get("contentBlockerAllowedDomains") ?? "")
            .lowercased()
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .filter { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") } }
            .map(String.init)
        return BlockerAllowlist(sites: contentBlockerAllowlist, domains: domains)
    }

    /// WebKit feature-flag overrides for `about:config`: `featureKey -> enabled`. Only flags that
    /// differ from their WebKit default are stored, so the set stays minimal and adapts across updates.
    var featureFlagOverrides: [String: Bool] {
        get {
            guard let json = get("featureFlagOverrides"),
                  let data = json.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
            return dict
        }
        set {
            let json = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}"
            set("featureFlagOverrides", value: json)
        }
    }
}
