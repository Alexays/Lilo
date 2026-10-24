import AppKit
import WebKit

/// What one profile's extensions may reach: load-time grants narrowed by user decisions and widened by runtime optional
/// permissions, persisted beside the installed record, plus `permissions.addHostAccessRequest`s on open tabs.
@MainActor
final class ExtensionAccess {
    /// Per extension; an extension the user decided nothing about has none.
    private(set) var states: [String: ExtensionStorage.AccessState] = [:]

    private struct HostAccessRequest {
        /// The URLs the request is offered on; nil for any.
        let pattern: WKWebExtension.MatchPattern?
        /// The origin the tab showed; a navigation to another one drops the request, as in Chrome.
        let origin: String
    }

    /// `permissions.addHostAccessRequest`s by Lilo tab, then extension.
    private var hostAccessRequests: [UUID: [String: HostAccessRequest]] = [:]

    private let storage: ExtensionStorage
    /// The loaded context of an extension.
    private let context: (String) -> WKWebExtensionContext?
    /// What the extension may reach changed: its user scripts and its row in the extensions panel follow.
    private let didChange: (String) -> Void

    init(storage: ExtensionStorage, context: @escaping (String) -> WKWebExtensionContext?, didChange: @escaping (String) -> Void) {
        self.storage = storage
        self.context = context
        self.didChange = didChange
    }

    func restore() async {
        states = (try? await storage.loadAccessStates()) ?? [:]
    }

    /// Changes and persists the extension's state.
    func update(_ extensionId: String, _ change: (inout ExtensionStorage.AccessState) -> Void) async {
        var state = states[extensionId] ?? ExtensionStorage.AccessState()
        change(&state)
        states[extensionId] = state.isEmpty ? nil : state
        try? await storage.setAccessState(id: extensionId, state)
    }

    func unloaded(_ extensionId: String) {
        for tabId in hostAccessRequests.keys { hostAccessRequests[tabId]?[extensionId] = nil }
    }

    func uninstalled(_ extensionId: String) {
        states[extensionId] = nil
    }

    // MARK: - Grants

    /// Grants what the manifest asks for, narrowed by the user's site access, plus the optional grants
    /// the extension obtained at runtime, and binds the user's command shortcuts. Extensions never run
    /// on the Web Store, as in Chrome: WebKit checks denied patterns before granted ones.
    func apply(to context: WKWebExtensionContext, extensionId: String) {
        let webExtension = context.webExtension
        let state = states[extensionId] ?? ExtensionStorage.AccessState()
        let distantFuture = Date.distantFuture
        // WKWebExtension hides an API until its permission is granted, even a manifest-declared one.
        var permissions = Dictionary(uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, distantFuture) })
        for raw in state.optionalPermissions {
            let permission = WKWebExtension.Permission(rawValue: raw)
            if webExtension.optionalPermissions.contains(permission) { permissions[permission] = distantFuture }
        }
        // Granted beyond the manifest so every worker can open its channel to Lilo (GapEvents). Real
        // hosts still need it declared (ExtensionControllerDelegate) and the host's allowed_origins.
        permissions[.nativeMessaging] = distantFuture
        context.grantedPermissions = permissions

        var patterns = Self.grantedMatchPatterns(requested: Self.baseMatchPatterns(for: webExtension), allowedHosts: state.hosts)
        for raw in state.optionalMatchPatterns {
            guard let pattern = try? WKWebExtension.MatchPattern(string: raw),
                  webExtension.optionalPermissionMatchPatterns.contains(where: { $0.matches(pattern) }) else { continue }
            patterns.insert(pattern)
        }
        context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: patterns.map { ($0, distantFuture) })
        let webStore = ["*://chromewebstore.google.com/*", "*://chrome.google.com/webstore/*"]
            .compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        context.deniedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: webStore.map { ($0, distantFuture) })
        // Content scripts and network rules reach private spaces' pages only with this, as in Chrome's incognito.
        context.hasAccessToPrivateData = state.allowsPrivateAccess == true
        if let shortcuts = state.commandShortcuts {
            for command in context.commands {
                guard let shortcut = shortcuts[command.id] else { continue }
                command.activationKey = shortcut.key
                command.modifierFlags = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
            }
        }
    }

    /// Persists what `permissions.request` granted or `permissions.remove` dropped, so a reload or a
    /// relaunch keeps it.
    func recordOptionalGrants(for extensionId: String) {
        guard let context = context(extensionId) else { return }
        let webExtension = context.webExtension
        let current = states[extensionId] ?? ExtensionStorage.AccessState()
        let granted = Self.grantedMatchPatterns(requested: Self.baseMatchPatterns(for: webExtension), allowedHosts: current.hosts)
        var state = current
        state.optionalPermissions = context.grantedPermissions.keys
            .filter { webExtension.optionalPermissions.contains($0) && !webExtension.requestedPermissions.contains($0) }
            .map(\.rawValue).sorted()
        state.optionalMatchPatterns = context.grantedPermissionMatchPatterns.keys
            .filter { !granted.contains($0) }
            .map(\.description).sorted()
        guard state != current else { return }
        states[extensionId] = state.isEmpty ? nil : state
        Task { try? await storage.setAccessState(id: extensionId, state) }
    }

    /// What a context is granted. With no restriction the manifest's own patterns stand; otherwise
    /// each allowed host becomes `*://*.host/*`, kept to the hosts the manifest actually asked for so
    /// the user can narrow access but never widen it past the install-time review.
    static func grantedMatchPatterns(
        requested: Set<WKWebExtension.MatchPattern>,
        allowedHosts: [String]
    ) -> Set<WKWebExtension.MatchPattern> {
        guard !allowedHosts.isEmpty else { return requested }
        return Set(allowedHosts.compactMap { host in
            guard let probe = URL(string: "https://\(host)/"),
                  requested.contains(where: { $0.matches(probe) })
            else { return nil }
            return try? WKWebExtension.MatchPattern(scheme: "*", host: "*.\(host)", path: "/*")
        })
    }

    /// The match patterns granted without asking, as Chrome grants them at install: host permissions,
    /// content-script and `externally_connectable` matches. Optional host permissions stay behind
    /// `permissions.request`.
    static func baseMatchPatterns(for webExtension: WKWebExtension) -> Set<WKWebExtension.MatchPattern> {
        webExtension.allRequestedMatchPatterns
            .subtracting(webExtension.optionalPermissionMatchPatterns)
            .union(webExtension.requestedPermissionMatchPatterns)
    }

    /// What `new` would be granted at load beyond what `old` is: its added manifest permissions, and
    /// the granted match patterns no old one already covers. Chrome's permission-increase check.
    static func addedAccess(from old: WKWebExtension, to new: WKWebExtension) -> (permissions: [String], matchPatterns: [String]) {
        let permissions = new.requestedPermissions.subtracting(old.requestedPermissions).map(\.rawValue).sorted()
        let oldPatterns = baseMatchPatterns(for: old)
        let patterns = baseMatchPatterns(for: new)
            .filter { pattern in !oldPatterns.contains { $0.matches(pattern) } }
            .map(\.description)
            .sorted()
        return (permissions, patterns)
    }

    // MARK: - User decisions

    /// Restricts an extension to `hosts` (empty restores the manifest's own). Applied to the live
    /// context, so pages loaded after the change see it without a reload of the extension.
    func setSiteAccess(extensionId: String, hosts: [String]) async {
        await update(extensionId) { $0.hosts = Self.normalizedHosts(hosts) }
        guard let context = context(extensionId) else { return }
        apply(to: context, extensionId: extensionId)
        didChange(extensionId)
    }

    /// Lets the extension run in private spaces. Applied to the live context like site access.
    func setPrivateAccess(extensionId: String, allowed: Bool) async {
        await update(extensionId) { $0.allowsPrivateAccess = allowed ? true : nil }
        context(extensionId)?.hasAccessToPrivateData = allowed
        didChange(extensionId)
    }

    /// Rebinds a command; a nil `key` removes its shortcut. Applied live and again at every load.
    func setCommandShortcut(extensionId: String, commandId: String, key: String?, modifiers: NSEvent.ModifierFlags) async {
        guard let command = context(extensionId)?.commands.first(where: { $0.id == commandId }) else { return }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        command.activationKey = key
        command.modifierFlags = flags
        await update(extensionId) {
            var shortcuts = $0.commandShortcuts ?? [:]
            shortcuts[commandId] = .init(key: key, modifiers: flags.rawValue)
            $0.commandShortcuts = shortcuts
        }
        didChange(extensionId)
    }

    /// Hosts as typed: a pasted URL keeps only its host, and case and duplicates are collapsed.
    nonisolated static func normalizedHosts(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        return hosts.compactMap { raw -> String? in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let separator = value.range(of: "://") { value = String(value[separator.upperBound...]) }
            value = String(value.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
            if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
            guard value.contains("."), !value.hasPrefix("."), !value.hasSuffix("."), seen.insert(value).inserted else { return nil }
            return value
        }
    }

    // MARK: - Host access requests

    private static func origin(of url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else { return "" }
        return "\(scheme)://\(host):\(url.port ?? -1)"
    }

    /// Chrome's checks for `permissions.addHostAccessRequest`, then the request replaces any the
    /// extension had on the tab. Returns Chrome's error, nil once added.
    func addHostAccessRequest(extensionId: String, tab: TabExtensionAdapter, pattern rawPattern: String?) -> String? {
        let pattern = rawPattern.flatMap { try? WKWebExtension.MatchPattern(string: $0) }
        if rawPattern != nil, pattern == nil { return "Extension cannot add a request with an invalid value for 'pattern'." }
        guard let context = context(extensionId) else { return "Extension not loaded" }
        let requested = context.webExtension.allRequestedMatchPatterns
        guard !requested.isEmpty else {
            return "Extension cannot add a host access request when it does not have any host permissions."
        }
        if let url = tab.url(for: context), context.hasAccess(to: url) {
            return "Extension cannot add a host access request for a host it already has access to."
        }
        if let pattern, !requested.contains(where: { $0.matches(pattern) || pattern.matches($0) }) {
            return "Extension cannot add a host access request with a pattern that does match any of its host permissions."
        }
        hostAccessRequests[tab.tabId, default: [:]][extensionId] = HostAccessRequest(pattern: pattern, origin: Self.origin(of: tab.url(for: context)))
        didChange(extensionId)
        return nil
    }

    /// `pattern` must be the one the request was added with, as in Chrome.
    func removeHostAccessRequest(extensionId: String, tab: TabExtensionAdapter, pattern rawPattern: String?) -> String? {
        let pattern = rawPattern.flatMap { try? WKWebExtension.MatchPattern(string: $0) }
        if rawPattern != nil, pattern == nil { return "Extension cannot remove a request with an invalid value for 'pattern'." }
        guard let request = hostAccessRequests[tab.tabId]?[extensionId], rawPattern == nil || request.pattern == pattern else {
            return "Extension cannot remove a host access request that doesn't exist."
        }
        hostAccessRequests[tab.tabId]?[extensionId] = nil
        didChange(extensionId)
        return nil
    }

    /// A committed navigation of the tab ends the requests made on another origin.
    func tabDidCommitNavigation(_ tabId: UUID, url: URL?) {
        guard let requests = hostAccessRequests[tabId] else { return }
        let origin = Self.origin(of: url)
        let kept = requests.filter { $0.value.origin == origin }
        guard kept.count != requests.count else { return }
        hostAccessRequests[tabId] = kept.isEmpty ? nil : kept
        for id in requests.keys where kept[id] == nil { didChange(id) }
    }

    /// The extension asks for the page `tab` shows, which it cannot reach yet.
    func showsHostAccessRequest(extensionId: String, context: WKWebExtensionContext, on tab: TabExtensionAdapter?) -> Bool {
        guard let tab, let request = hostAccessRequests[tab.tabId]?[extensionId],
              let url = tab.url(for: context), Self.origin(of: url) == request.origin else { return false }
        return (request.pattern?.matches(url) ?? true) && !context.hasAccess(to: url)
    }

    /// The user accepted the request on `tab`, the active one: the extension gets the site for good,
    /// as Chrome grants the site's top origin.
    func acceptHostAccessRequest(extensionId: String, on tab: TabExtensionAdapter?) async {
        guard let tab, let context = context(extensionId),
              let url = tab.url(for: context), let scheme = url.scheme, let host = url.host else { return }
        hostAccessRequests[tab.tabId]?[extensionId] = nil
        let hosts = states[extensionId]?.hosts ?? []
        if !hosts.isEmpty, Self.baseMatchPatterns(for: context.webExtension).contains(where: { $0.matches(url) }) {
            // A host the user's site access left out: it joins the allowed ones.
            await setSiteAccess(extensionId: extensionId, hosts: hosts + [host])
        } else if let pattern = try? WKWebExtension.MatchPattern(string: "\(scheme)://\(host)/*") {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
            recordOptionalGrants(for: extensionId)
        }
        didChange(extensionId)
    }
}
