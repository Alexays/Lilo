import CryptoKit
import Foundation
import WebKit
import os

/// The subset of `WKEngineFactory` the filter pipeline drives; lets tests observe applied tables.
@MainActor
protocol FilterRuleApplying: AnyObject {
    /// Applies the rules and every filter script at once; implementations must rescript controllers once.
    func setFilterTables(rulesTag: String?, rules: String?, scripts: WKEngineFactory.FilterScripts)
    func rebuildBlocker(allowlist: BlockerAllowlist) async
}

/// What the content blocker stands down for: whole sites (every request their pages make), and
/// request domains on every page.
struct BlockerAllowlist: Equatable, Sendable {
    var sites: [String] = []
    var domains: [String] = []

    /// Bot-defense and captcha vendors: privacy lists block their sensors as trackers, and a site whose sensor never
    /// reports challenges every visit with a captcha.
    static let botDefenseDomains = [
        "perimeterx.net", "px-cdn.net", "px-cloud.net", "px-client.net", "pxchk.net",
        "datadome.co", "captcha-delivery.com", "arkoselabs.com", "funcaptcha.com", "hcaptcha.com", "challenges.cloudflare.com"
    ]
}

extension WKEngineFactory: FilterRuleApplying {}

/// Keeps the content blocker's rules current from remote filter lists: fetch, convert, cache, compile. On any failure the engine keeps
/// whatever it had (the bundled list as last resort), so blocking never drops to nothing.
@MainActor
final class FilterListService {
    private static let logger = Logger(liloCategory: "filter-lists")

    /// One conversion as cached on disk. `rulesTag` names the compiled rule list, so a launch can look it
    /// up without reading the multi-MB `rules`.
    struct Conversion: Sendable {
        let rules: String
        let rulesTag: String
        let cosmetic: String
        let sites: String
        let scriptlets: String
        let procedural: String
        /// declarativeNetRequest rules for the built-in extension, without ids.
        let extensionRules: String
        /// The tables above spliced into their scripts, cached so a launch skips the splice.
        let scripts: WKEngineFactory.FilterScripts
        /// `cacheStamp` of the lists converted.
        let stamp: String
        let status: Status
    }

    /// The filter-list categories the user keeps on, and the languages that pick the regional lists.
    struct ListSelection: Equatable, Sendable {
        var trackers = true
        var cookieNotices = true
        var annoyances = false
        var badware = true
        var regional = true
        var languages: [String] = []
    }

    /// Regional ad lists by language code.
    private nonisolated static let regionalLists: [String: String] = [
        "fr": "https://easylist-downloads.adblockplus.org/liste_fr.txt",
        "de": "https://easylist.to/easylistgermany/easylistgermany.txt",
        "it": "https://easylist-downloads.adblockplus.org/easylistitaly.txt",
        "es": "https://easylist-downloads.adblockplus.org/easylistspanish.txt",
        "nl": "https://easylist-downloads.adblockplus.org/easylistdutch.txt",
        "pl": "https://raw.githubusercontent.com/MajkiIT/polish-ads-filter/master/polish-adblock-filters/adblock.txt",
        "ru": "https://easylist-downloads.adblockplus.org/advblock.txt",
        "uk": "https://easylist-downloads.adblockplus.org/advblock.txt",
        "zh": "https://easylist-downloads.adblockplus.org/easylistchina.txt",
        "ja": "https://raw.githubusercontent.com/k2jp/abp-japanese-filters/master/abpjf.txt"
    ]

    /// Lists to fetch, in order. The converter ignores `!#include`, so uBO lists come with their sublists; uBO's quick fixes come first
    /// because every cap keeps the earliest rules, and they carry the fast-moving fixes.
    nonisolated static let trustedListPrefix = "https://ublockorigin.github.io/uAssetsCDN/filters/"

    nonisolated static func sources(for selection: ListSelection) -> [URL] {
        let ubo = trustedListPrefix
        let thirdParty = "https://ublockorigin.github.io/uAssetsCDN/thirdparties/"
        var urls = [ubo + "quick-fixes.txt", "https://easylist.to/easylist/easylist.txt"]
        urls += ["filters", "filters-general", "filters-2020", "filters-2021", "filters-2022", "filters-2023", "filters-2024",
                 "filters-2025", "filters-2026", "ubo-link-shorteners", "resource-abuse"].map { ubo + $0 + ".txt" }
        if selection.regional {
            for language in selection.languages {
                let code = String(language.prefix { $0 != "-" && $0 != "_" }).lowercased()
                if let list = regionalLists[code], !urls.contains(list) { urls.append(list) }
            }
        }
        if selection.trackers { urls += ["https://easylist.to/easylist/easyprivacy.txt", ubo + "privacy.txt"] }
        if selection.badware { urls.append(ubo + "badware.txt") }
        if selection.cookieNotices { urls += [thirdParty + "easylist-cookies.txt", ubo + "annoyances-cookies.txt"] }
        if selection.annoyances {
            urls.append(ubo + "annoyances-others.txt")
            urls += ["easylist-annoyances", "easylist-newsletters", "easylist-notifications", "easylist-social"]
                .map { thirdParty + $0 + ".txt" }
        }
        return urls.map { URL(string: $0)! }
    }

    /// Caps the content rules, css-display-none rules included; the engine compiles them in several lists.
    static let maxRules = 420_000
    /// Caps the generic cosmetic selectors, token table and native complex selectors together.
    static let maxCosmeticSelectors = 60_000
    /// Caps the per-host cosmetic table (selectors, exceptions, generichide), read in main frames only.
    private static let maxSiteCosmetics = 150_000
    /// Caps the per-host scriptlet table; bounds the size of the table injected into every frame.
    private static let maxScriptletEntries = 80_000
    /// Caps the per-host procedural selector table.
    private static let maxProceduralSelectors = 15_000
    /// uBO's quick fixes change several times a day; an unchanged list costs a 304, an unchanged set
    /// no conversion.
    private static let refreshInterval: TimeInterval = 4 * 60 * 60
    /// How old the cache may grow while refreshes keep missing a source before a partial set replaces it.
    private static let partialRefreshAcceptAge: TimeInterval = 3 * refreshInterval
    /// Bumped whenever the conversion changes: a cache in another format is reconverted at launch
    /// instead of serving the old conversion until the next scheduled refresh.
    private nonisolated static let cacheFormat = "9"

    /// Names the conversion format and the lists it was made from: a cache stamped otherwise is redone.
    nonisolated static func cacheStamp(for sources: [URL]) -> String {
        cacheFormat + " " + WKEngineFactory.stableHash8(sources.map(\.absoluteString).joined(separator: " "))
    }

    private let engineFactory: FilterRuleApplying
    private let allowlistProvider: @MainActor () -> BlockerAllowlist
    /// Read at each refresh: the lists follow the settings.
    var listSelection: @MainActor () -> ListSelection = { ListSelection() }
    /// The built-in extension was rewritten; the profiles reload it.
    var onBlockerExtensionChanged: (() -> Void)?
    private(set) var isRefreshing = false
    /// What the last conversion produced, for the settings page.
    private(set) var status = Status()
    private var refreshTimer: DispatchSourceTimer?
    private var isNetworkRetryScheduled = false
    /// The latest built-in extension write: each one waits for the previous, as all share one folder.
    private var extensionInstall: Task<Void, Never>?

    /// The last conversion: when, from which source texts, and what it holds.
    struct Status: Codable, Equatable {
        var updated: Date?
        var sourceHash = ""
        var lists = 0
        /// SHA-256 of everything the conversion produced: an equal one leaves the cache as it is.
        var outputHash: String?
    }

    /// Conditional requests against an on-disk HTTP cache: a list unchanged since the last fetch costs a 304.
    /// Background traffic, kept off Low Data Mode networks: the cached rules keep blocking meanwhile.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .background
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 120 << 20,
                                          directory: cacheDirectory.appendingPathComponent("filter-lists-http", isDirectory: true))
        return URLSession(configuration: configuration)
    }()

    // Test seams: list fetching, network-path reads, and cache persistence.
    var fetchList: @Sendable (URL) async -> String? = { url in
        guard let (data, response) = try? await FilterListService.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
    /// Registers the retry only while the path is down: runWhenSatisfied fires at once on a
    /// satisfied path, so registering an online failure would loop the refresh immediately.
    var retryWhenBackOnline: @MainActor (@escaping @MainActor () -> Void) -> Bool = { retry in
        guard !NetworkPathStatus.shared.isSatisfied else { return false }
        NetworkPathStatus.shared.runWhenSatisfied(retry)
        return true
    }
    /// Writes the built-in extension's folder; false when nothing was written.
    var writeExtension: @Sendable (_ rules: String, _ allowlist: BlockerAllowlist) -> Bool = { rules, allowlist in
        FilterListService.writeBlockerExtension(rules: rules, allowlist: allowlist)
    }
    /// Writes multi-MB cache files; hops off the main actor like start()'s read path does.
    var persistCache: @Sendable (Conversion) -> Void = { conversion in
        Task.detached(priority: .utility) {
            FilterListService.writeCache(conversion)
        }
    }

    init(engineFactory: FilterRuleApplying, allowlistProvider: @escaping @MainActor () -> BlockerAllowlist) {
        self.engineFactory = engineFactory
        self.allowlistProvider = allowlistProvider
    }

    deinit {
        refreshTimer?.cancel()
    }

    // MARK: - Lifecycle

    /// Apply the cached conversion right away (if any), then refresh from the network if it's stale.
    /// The cache reads and script splicing run off the main actor; only the resulting
    /// `engineFactory.set*` call and rebuild hop back.
    func start() {
        let rulesTagURL = Self.rulesTagURL
        let cosmeticURL = Self.cosmeticURL
        let sitesURL = Self.sitesURL
        let formatURL = Self.formatURL
        let scriptletsURL = Self.scriptletsURL
        let proceduralURL = Self.proceduralURL
        let scriptsKeyURL = Self.scriptsKeyURL
        let stamp = Self.cacheStamp(for: Self.sources(for: listSelection()))
        status = Self.readStatus() ?? Status()
        Task.detached(priority: .userInitiated) { [weak self] in
            // A compile miss reads the multi-MB rules itself: the tag is all a launch needs.
            guard let rulesTag = try? String(contentsOf: rulesTagURL, encoding: .utf8), !rulesTag.isEmpty else { return }
            // The compiled list is a lookup by tag: attach it before reading and splicing the script
            // tables, so the tab restored at launch does not start loading unblocked meanwhile.
            await self?.applyCachedFilters(rulesTag: rulesTag, scripts: .init(), isOutdated: false)
            // The scripts yield to the tabs restoring meanwhile, so they run at utility priority.
            let (format, scripts) = await Task.detached(priority: .utility) { [rulesTag] () -> (String?, WKEngineFactory.FilterScripts) in
                let format = try? String(contentsOf: formatURL, encoding: .utf8)
                let scriptsKey = FilterListService.scriptsKey(rulesTag: rulesTag, stamp: format ?? "")
                let cachedScripts: WKEngineFactory.FilterScripts? = FilterListService.scriptsWriteQueue.sync {
                    guard (try? String(contentsOf: scriptsKeyURL, encoding: .utf8)) == scriptsKey else { return nil }
                    return WKEngineFactory.FilterScripts(
                        genericCosmetics: try? String(contentsOf: FilterListService.genericCosmeticsScriptURL, encoding: .utf8),
                        procedural: try? String(contentsOf: FilterListService.proceduralScriptURL, encoding: .utf8),
                        scriptlets: try? String(contentsOf: FilterListService.scriptletsScriptURL, encoding: .utf8)
                    )
                }
                if let cachedScripts { return (format, cachedScripts) }
                let signpost = PerfSignposts.energy.beginInterval("filterSplice")
                let scripts = WKEngineFactory.makeFilterScripts(
                    cosmetic: try? String(contentsOf: cosmeticURL, encoding: .utf8),
                    sites: try? String(contentsOf: sitesURL, encoding: .utf8),
                    scriptlets: try? String(contentsOf: scriptletsURL, encoding: .utf8),
                    procedural: try? String(contentsOf: proceduralURL, encoding: .utf8)
                )
                PerfSignposts.energy.endInterval("filterSplice", signpost)
                FilterListService.writeScripts(scripts, key: scriptsKey)
                return (format, scripts)
            }.value
            guard let self else { return }
            await self.applyCachedFilters(rulesTag: rulesTag, scripts: scripts, isOutdated: format != stamp)
        }
        // With rules already cached, the fetch and conversion wait out the first page loads they
        // would compete with for bandwidth and CPU.
        let refreshDelay: Duration = Self.hasUsableCache ? .seconds(30) : .zero
        Task {
            try? await Task.sleep(for: refreshDelay)
            await refreshIfStale()
        }
        startRefreshTimer()
    }

    /// In-session periodic refresh for long-lived processes; refreshIfStale self-gates on the TTL,
    /// so the generous leeway and early fires are harmless.
    private func startRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.refreshInterval,
            repeating: Self.refreshInterval,
            leeway: .seconds(600)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor in await self?.refreshIfStale() }
        }
        timer.resume()
        refreshTimer = timer
    }

    /// `isOutdated` marks a cache written by another conversion format or from other lists: refresh now
    /// rather than waiting out the staleness window.
    func applyCachedFilters(rulesTag: String, scripts: WKEngineFactory.FilterScripts, isOutdated: Bool) async {
        let signpost = PerfSignposts.energy.beginInterval("applyCachedFilters")
        engineFactory.setFilterTables(rulesTag: rulesTag, rules: nil, scripts: scripts)
        await engineFactory.rebuildBlocker(allowlist: allowlistProvider())
        PerfSignposts.energy.endInterval("applyCachedFilters", signpost)
        if isOutdated {
            await refreshIfStale(force: true)
        }
    }

    /// A refresh the user asked for, or a list setting changed: now, whatever the cache's age.
    func refreshNow() async {
        await refresh(acceptPartial: true)
    }

    func refreshIfStale(force: Bool = false) async {
        if !force, let last = Self.lastRefresh(), Date().timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        // Forced only for a cache in another format or from other lists (see applyCachedFilters): not
        // the set the partial-fetch guard protects, so any lists beat it.
        await refresh(acceptPartial: force)
    }

    // MARK: - Refresh

    private func refresh(acceptPartial: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sources = Self.sources(for: listSelection())
        let stamp = Self.cacheStamp(for: sources)
        let logger = Self.logger
        let fetch = fetchList
        // Fetched in parallel, but assembled back in source order: order carries exception/block
        // priority downstream, so a slot is reserved per source and a failed fetch just leaves a hole.
        var fetched = [String?](repeating: nil, count: sources.count)
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, url) in sources.enumerated() {
                group.addTask {
                    guard let text = await fetch(url) else {
                        logger.error("filter list fetch failed: \(url.absoluteString, privacy: .public)")
                        return (index, nil)
                    }
                    return (index, text)
                }
            }
            for await (index, text) in group {
                fetched[index] = text
            }
        }
        // Only uBO's own lists may run its trusted scriptlets; another list cannot claim the trust itself.
        var texts = zip(sources, fetched).compactMap { url, text -> String? in
            guard let text else { return nil }
            if url.absoluteString.hasPrefix(Self.trustedListPrefix) { return "!#trusted on\n" + text + "\n!#trusted off" }
            return text.contains("!#trusted") ? text.replacingOccurrences(of: "!#trusted", with: "! #trusted") : text
        }
        fetched = []
        guard !texts.isEmpty else {  // keep existing rules
            scheduleRetryWhenOnline()
            return
        }
        // A partial set would replace a complete cached one: keep the cache and try again next
        // interval, unless it has aged past the point where fresh lists beat the missing one (a source
        // gone for good). A first run has no cache, so any list beats the bundled one.
        if !acceptPartial, texts.count < sources.count, let age = Self.cacheAge, age < Self.partialRefreshAcceptAge {
            logger.error("filter lists partially fetched (\(texts.count, privacy: .public)/\(sources.count, privacy: .public)); keeping the cache")
            Task.detached(priority: .utility) { FilterListService.markRefreshed() }
            return
        }

        let previousHash = status.sourceHash
        let listCount = texts.count
        let limit = Self.maxRules
        let cosmeticLimit = Self.maxCosmeticSelectors
        let siteCap = Self.maxSiteCosmetics
        let scriptletCap = Self.maxScriptletEntries
        let proceduralCap = Self.maxProceduralSelectors
        let result = await Task.detached(priority: .utility) { [texts] () -> Conversion? in
            // One text, in source order: a `$badfilter` in one list must reach the rule it disables in another.
            let text = texts.joined(separator: "\n")
            // The same lists in the same format convert to the same rules: only the check is recorded.
            let sourceHash = WKEngineFactory.stableHash8(text)
            if sourceHash == previousHash, (try? String(contentsOf: FilterListService.formatURL, encoding: .utf8)) == stamp {
                FilterListService.markRefreshed()
                return nil
            }
            var out = FilterListConverter.convert(text)
            // `<a ping>` click-tracking beacons, everywhere; a block, so exceptions and the allowlist still win.
            out.blocks.insert(["trigger": ["url-filter": ".*", "resource-type": ["ping"]], "action": ["type": "block"]], at: 0)
            // Complex generic cosmetics become native css-display-none rules; exceptions
            // come after them (so their ignore-previous-rules overrides earlier rules) and are reserved ahead
            // of blocks: dropping an exception could break a site, a block can't.
            let generic = FilterListConverter.genericCosmetics(from: out.cosmetic, exceptions: out.cosmeticExceptions, cap: cosmeticLimit)
            let combined = FilterListConverter.combinedRules(
                blocks: out.blocks, cssRules: generic.cssRules, exceptions: out.exceptions, important: out.important, limit: limit
            )
            guard !combined.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: combined, options: .sortedKeys),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            // Space-joined token strings: splitting one string is several times cheaper for JSC than
            // parsing an array of thousands of strings, on every main-frame navigation.
            let tokens: [String: Any] = [
                "classes": generic.classes.joined(separator: " "), "ids": generic.ids.joined(separator: " "),
                "keyed": generic.keyed, "links": generic.links
            ]
            let cosmeticJSON = (try? JSONSerialization.data(withJSONObject: tokens, options: .sortedKeys))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let siteTable = FilterListConverter.siteCosmeticTable(
                cosmetics: out.domainCosmetic, exceptions: out.cosmeticExceptions, genericHide: out.genericHide, cap: siteCap
            )
            let sitesJSON = (try? JSONSerialization.data(withJSONObject: siteTable, options: .sortedKeys))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let table = FilterListConverter.scriptletTable(from: out.scriptlets, exceptions: out.scriptletExceptions, cap: scriptletCap)
            let scriptletsJSON = (try? JSONSerialization.data(withJSONObject: table, options: .sortedKeys))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let proceduralTable = FilterListConverter.siteCosmeticTable(
                cosmetics: out.procedural, exceptions: out.proceduralExceptions, genericHide: [], cap: proceduralCap
            )
            let proceduralJSON = (try? JSONSerialization.data(withJSONObject: proceduralTable, options: .sortedKeys))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let extensionRulesJSON = (try? JSONSerialization.data(withJSONObject: out.extensionRules, options: .sortedKeys))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            var status = Status(updated: Date(), sourceHash: sourceHash, lists: listCount)
            var hasher = SHA256()
            for var output in [json, cosmeticJSON, sitesJSON, scriptletsJSON, proceduralJSON, extensionRulesJSON] {
                output.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
            }
            status.outputHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let scripts = WKEngineFactory.makeFilterScripts(cosmetic: cosmeticJSON, sites: sitesJSON, scriptlets: scriptletsJSON, procedural: proceduralJSON)
            return Conversion(
                rules: json, rulesTag: WKEngineFactory.stableHash8(json), cosmetic: cosmeticJSON,
                sites: sitesJSON, scriptlets: scriptletsJSON, procedural: proceduralJSON,
                extensionRules: extensionRulesJSON, scripts: scripts, stamp: stamp, status: status
            )
        }.value

        texts = []
        guard let conversion = result else { return }
        // New list headers (uBO's quick fixes change several times a day) often convert to the same
        // output: only the check is recorded, nothing is rewritten, reinstalled or rescripted.
        let unchanged = conversion.status.outputHash == status.outputHash && Self.hasUsableCache
        status = conversion.status
        guard !unchanged else {
            Task.detached(priority: .utility) { [status, stamp] in FilterListService.writeStatus(status, stamp: stamp) }
            return
        }
        Self.logger.log("filter lists updated (\(conversion.rules.utf8.count / 1024, privacy: .public) KB rules, \(conversion.cosmetic.utf8.count / 1024, privacy: .public) KB cosmetic, \(conversion.sites.utf8.count / 1024, privacy: .public) KB site cosmetics, \(conversion.scriptlets.utf8.count / 1024, privacy: .public) KB scriptlets, \(conversion.procedural.utf8.count / 1024, privacy: .public) KB procedural)")
        persistCache(conversion)
        await installBlockerExtension(rules: conversion.extensionRules)
        engineFactory.setFilterTables(rulesTag: conversion.rulesTag, rules: conversion.rules, scripts: conversion.scripts)
        await engineFactory.rebuildBlocker(allowlist: allowlistProvider())
    }

    /// Writes the built-in extension with the current allowlist, from `rules` or else the cached ones.
    func installBlockerExtension(rules: String? = nil) async {
        let previous = extensionInstall
        let install = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let allowlist = allowlistProvider()
            let write = writeExtension
            let installed = await Task.detached(priority: .utility) {
                guard let rules = rules ?? (try? String(contentsOf: FilterListService.extensionRulesURL, encoding: .utf8)) else { return false }
                return write(rules, allowlist)
            }.value
            if installed { onBlockerExtensionChanged?() }
        }
        extensionInstall = install
        await install.value
    }

    /// The content blocker's built-in extension: declarativeNetRequest rules for what content rules
    /// cannot do (stand-in resources, removed parameters), the user's allowlist, and those resources.
    nonisolated static var blockerExtensionURL: URL { cacheDirectory.appendingPathComponent("BlockerExtension", isDirectory: true) }

    private nonisolated static func writeBlockerExtension(rules: String, allowlist: BlockerAllowlist) -> Bool {
        guard var list = (try? JSONSerialization.jsonObject(with: Data(rules.utf8))) as? [[String: Any]],
              let resources = Bundle.appResourceURL("BlockerResources", extension: nil) else { return false }
        // An allowlisted site turns everything off in its frames, ahead of every other rule.
        list += allowlist.sites.map {
            ["priority": 10, "action": ["type": "allowAllRequests"],
             "condition": ["requestDomains": [$0], "resourceTypes": ["main_frame", "sub_frame"]]]
        }
        if !allowlist.domains.isEmpty {
            list.append(["priority": 10, "action": ["type": "allow"], "condition": ["requestDomains": allowlist.domains]])
        }
        for index in list.indices { list[index]["id"] = index + 1 }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Lilo content blocker", "version": "1",
            "permissions": ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"],
            "host_permissions": ["<all_urls>"],
            "web_accessible_resources": [["resources": ["resources/*"], "matches": ["<all_urls>"]]],
            "declarative_net_request": ["rule_resources": [["id": "filters", "enabled": true, "path": "rules.json"]]]
        ]
        let directory = blockerExtensionURL
        var ok = false
        loggingPersistenceError("filterCache.writeBlockerExtension") {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: resources, to: directory.appendingPathComponent("resources"))
            try JSONSerialization.data(withJSONObject: list).write(to: directory.appendingPathComponent("rules.json"))
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
            ok = true
        }
        return ok
    }

    /// Every source failing while the network path is down is a connectivity failure; refresh once
    /// when it comes back. Non-network failures wait for the periodic timer instead.
    private func scheduleRetryWhenOnline() {
        guard !isNetworkRetryScheduled else { return }
        isNetworkRetryScheduled = retryWhenBackOnline { [weak self] in
            guard let self else { return }
            self.isNetworkRetryScheduled = false
            Task { await self.refreshIfStale() }
        }
    }

    // MARK: - Cache (BuildIdentity.appSupportDirectory)

    // The cache paths are nonisolated so the detached writeCache/read paths can use them.
    /// Tests get a scratch directory of their own, so they never read or write the real cache.
    private nonisolated static let cacheDirectory: URL = {
        let fileManager = FileManager.default
        if ProcessInfo.isRunningUnderXCTest {
            return fileManager.temporaryDirectory.appendingPathComponent("LiloTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return URL(fileURLWithPath: BuildIdentity.appSupportDirectory, isDirectory: true)
    }()
    /// Read by `WKEngineFactory.compile` to re-source external rules whose in-memory copy was released.
    nonisolated static var cacheURL: URL { cacheDirectory.appendingPathComponent("filter-rules.json") }

    /// Cheap boot probe (one stat): the tag is written after the rules it names, so a non-empty one
    /// means `start()` will supersede the bundled list and the boot-time bundled compile can be skipped.
    nonisolated static var hasUsableCache: Bool {
        ((try? rulesTagURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }
    private nonisolated static var rulesTagURL: URL { cacheDirectory.appendingPathComponent("filter-rules.tag") }
    private nonisolated static var cosmeticURL: URL { cacheDirectory.appendingPathComponent("filter-generic-cosmetics.json") }
    private nonisolated static var sitesURL: URL { cacheDirectory.appendingPathComponent("filter-site-cosmetics.json") }
    private nonisolated static var formatURL: URL { cacheDirectory.appendingPathComponent("filter-format") }
    private nonisolated static var extensionRulesURL: URL { cacheDirectory.appendingPathComponent("filter-extension-rules.json") }
    private nonisolated static var statusURL: URL { cacheDirectory.appendingPathComponent("filter-status.json") }

    private static func readStatus() -> Status? {
        (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
    }

    private nonisolated static var scriptletsURL: URL { cacheDirectory.appendingPathComponent("filter-scriptlets.json") }
    private nonisolated static var proceduralURL: URL { cacheDirectory.appendingPathComponent("filter-procedural.json") }
    private nonisolated static var metaURL: URL { cacheDirectory.appendingPathComponent("filter-rules.meta") }
    private nonisolated static var genericCosmeticsScriptURL: URL { cacheDirectory.appendingPathComponent("filter-generic-cosmetics.js") }
    private nonisolated static var proceduralScriptURL: URL { cacheDirectory.appendingPathComponent("filter-procedural.js") }
    private nonisolated static var scriptletsScriptURL: URL { cacheDirectory.appendingPathComponent("filter-scriptlets.js") }
    /// The `scriptsKey` the cached scripts were spliced under; without it they are never read.
    private nonisolated static var scriptsKeyURL: URL { cacheDirectory.appendingPathComponent("filter-scripts.key") }

    /// Names the tables and the build behind spliced scripts: the templates and their encoding ship
    /// with the app, so an app update (or a dev rebuild) re-splices.
    private nonisolated static func scriptsKey(rulesTag: String, stamp: String) -> String {
        let build = [Bundle.main.executableURL, Bundle.appResourceURL("GenericCosmetics", extension: "js"),
                     Bundle.appResourceURL("ProceduralCosmetics", extension: "js"), Bundle.appResourceURL("Scriptlets", extension: "js")]
            .map { url in
                (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    .map { String($0.timeIntervalSince1970) } ?? "-"
            }
        return ([rulesTag, stamp] + build).joined(separator: " ")
    }

    /// Serializes the scripts' writes (launch-time splice, refresh) and the launch-time read, so one
    /// set's files never mix with the other's key.
    private nonisolated static let scriptsWriteQueue = DispatchQueue(label: "fr.arouillard.lilo.filter-scripts", qos: .utility)

    /// The key goes last: a script left beside a key it does not match would inject stale tables.
    private nonisolated static func writeScripts(_ scripts: WKEngineFactory.FilterScripts, key: String) {
        scriptsWriteQueue.sync {
            loggingPersistenceError("filterCache.writeScripts") {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: scriptsKeyURL)
                for (script, url) in [(scripts.genericCosmetics, genericCosmeticsScriptURL), (scripts.procedural, proceduralScriptURL),
                                      (scripts.scriptlets, scriptletsScriptURL)] {
                    if let script {
                        try script.write(to: url, atomically: true, encoding: .utf8)
                    } else {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                try key.write(to: scriptsKeyURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Age of the cached rules, nil without a cache.
    private nonisolated static var cacheAge: TimeInterval? {
        (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            .map { Date().timeIntervalSince($0) }
    }

    /// Stamps a refresh attempt without new rules, so launches do not refetch every list meanwhile.
    private nonisolated static func markRefreshed() {
        loggingPersistenceError("filterCache.markRefreshed") {
            try String(Date().timeIntervalSince1970).write(to: metaURL, atomically: true, encoding: .utf8)
        }
    }

    private static func lastRefresh() -> Date? {
        guard let raw = try? String(contentsOf: metaURL, encoding: .utf8),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private nonisolated static func writeStatus(_ status: Status, stamp: String) {
        loggingPersistenceError("filterCache.writeStatus") {
            try JSONEncoder().encode(status).write(to: statusURL, options: .atomic)
            try stamp.write(to: formatURL, atomically: true, encoding: .utf8)
            try String(Date().timeIntervalSince1970).write(to: metaURL, atomically: true, encoding: .utf8)
        }
    }

    private nonisolated static func writeCache(_ conversion: Conversion) {
        // The tag goes first and comes back after the rules: left beside rules it does not describe, it
        // would name a stale compiled list. The meta timestamp comes last: writing it after a failed
        // rules write would mark a broken cache fresh for the whole refresh interval.
        loggingPersistenceError("filterCache.write") {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: rulesTagURL)
            try conversion.rules.write(to: cacheURL, atomically: true, encoding: .utf8)
            try conversion.rulesTag.write(to: rulesTagURL, atomically: true, encoding: .utf8)
            try conversion.cosmetic.write(to: cosmeticURL, atomically: true, encoding: .utf8)
            try conversion.sites.write(to: sitesURL, atomically: true, encoding: .utf8)
            try conversion.extensionRules.write(to: extensionRulesURL, atomically: true, encoding: .utf8)
            try conversion.scriptlets.write(to: scriptletsURL, atomically: true, encoding: .utf8)
            try conversion.procedural.write(to: proceduralURL, atomically: true, encoding: .utf8)
        }
        writeStatus(conversion.status, stamp: conversion.stamp)
        writeScripts(conversion.scripts, key: scriptsKey(rulesTag: conversion.rulesTag, stamp: conversion.stamp))
    }
}
