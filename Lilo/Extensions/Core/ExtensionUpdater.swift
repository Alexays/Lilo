import Foundation
import WebKit
import os

/// Updates one profile's Chrome Web Store extensions: periodic and requested checks against Google's
/// update service, then the download, review and swap of each newer version, keeping the extension's
/// id and so its storage. A check covers every profile, which share its requests and downloads.
@MainActor
final class ExtensionUpdater {
    private static let logger = Logger(liloCategory: "extension-updater")

    /// Chrome checks about every five hours.
    static let checkInterval: TimeInterval = 5 * 60 * 60
    /// The next periodic check after one that never reached the service.
    static let retryInterval: TimeInterval = 30 * 60
    /// Extensions per update-check request, keeping the GET URL well under server limits.
    private static let batchSize = 25
    /// When the last check finished, kept across launches.
    static let lastCheckKey = "extensionUpdateLastCheck"

    /// Every profile's updater, which each check covers.
    private static let updaters = NSHashTable<ExtensionUpdater>.weakObjects()
    /// The check under way, which a check asked for meanwhile waits for.
    private static var runningCheck: Task<Bool, Never>?
    /// Extracted packages by "id@version", shared by the profiles: an update found by several, or waiting for a running
    /// worker to stop, downloads once. Dropped once no update uses or waits for it.
    private static var packages: [String: (download: Task<URL, Error>, users: Int)] = [:]

    /// Weak: the registry owns the updater. Each method holds it for its whole run.
    private weak var registry: ProfileExtensionRegistry?
    /// Weak-self loop: it ends once the updater is released.
    private var checkTask: Task<Void, Never>?
    /// Newer versions a check found while automatic updates are off, or waiting for a running worker to stop.
    private(set) var availableUpdates: [String: (current: String, latest: String)] = [:]
    /// Outcome of the last check, sent to the settings page alongside the extension payloads.
    private(set) var status: [String: Any] = [:]
    /// Set when `status` changed since the extensions panel last heard.
    var statusChanged = false
    /// When each extension last called `runtime.requestUpdateCheck`.
    private var lastRequestedChecks: [String: Date] = [:]
    /// The update of each extension under way and the version it installs, which another update of it waits for: two
    /// would swap the same folder.
    private var updatesInFlight: [String: (latest: String?, task: Task<Bool, Never>)] = [:]

    init(registry: ProfileExtensionRegistry) {
        self.registry = registry
        Self.updaters.add(self)
    }

    /// Idempotent. The interval spans launches and profiles: the first pass waits at least 90s so it does not compete with
    /// launch, and a profile whose wait ends after another profile's check waits for the next one.
    func start(
        now: Date = Date(),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        guard checkTask == nil, let registry else { return }
        Self.updaters.add(self)
        let lastCheck = registry.settingsStore?.get(Self.lastCheckKey).flatMap(TimeInterval.init) ?? 0
        if lastCheck > 0, status.isEmpty {
            status = ["lastCheck": lastCheck]
            statusChanged = true
            registry.notifyExtensionsChanged()
        }
        let firstDelay = max(90, min(Self.checkInterval, Self.checkInterval - (now.timeIntervalSince1970 - lastCheck)))
        checkTask = Task { [weak self] in
            var delay = firstDelay
            while !Task.isCancelled {
                await sleep(.seconds(delay))
                guard let self, !Task.isCancelled else { break }
                let lastCheck = self.registry?.settingsStore?.get(Self.lastCheckKey).flatMap(TimeInterval.init) ?? 0
                let remaining = Self.checkInterval - (Date().timeIntervalSince1970 - lastCheck)
                if remaining > 90 {
                    delay = min(Self.checkInterval, remaining)
                    continue
                }
                // Under constrained power the network pass is skipped; the next tick retries.
                var reachedService = true
                if !HiddenSpaceLifecycleController.systemIsPowerConstrained() {
                    reachedService = await self.checkForUpdates(inBackground: true)
                }
                delay = reachedService ? Self.checkInterval : Self.retryInterval
            }
        }
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
        Self.updaters.remove(self)
    }

    /// Checks the Web Store extensions of every profile, enabled or not, with Google's update service, applying or only listing
    /// newer versions per the auto-update setting. A check already under way is waited for instead. A background check is
    /// background traffic and skips Low Data Mode networks. False when no request reached the service: that check is not
    /// recorded, so the next one comes sooner.
    @discardableResult
    func checkForUpdates(inBackground: Bool = false) async -> Bool {
        if Self.runningCheck == nil {
            var updaters = Self.updaters.allObjects
            if !updaters.contains(where: { $0 === self }) { updaters.append(self) }
            Self.runningCheck = Task {
                let reachedService = await Self.check(updaters, inBackground: inBackground)
                Self.runningCheck = nil
                Self.prunePackages()
                return reachedService
            }
        }
        return await Self.runningCheck?.value ?? true
    }

    /// One request per batch of ids for all `updaters`, then each applies or lists what is newer than its own copies. Only
    /// copies under Lilo's extensions directory qualify: unpacked folders are never replaced.
    private static func check(_ updaters: [ExtensionUpdater], inBackground: Bool) async -> Bool {
        var checking: [(updater: ExtensionUpdater, candidates: [(id: String, version: String)])] = []
        for updater in updaters {
            guard let registry = updater.registry, registry.files.directory != nil else { continue }
            updater.publishStatus(["checking": true, "lastCheck": updater.status["lastCheck"] ?? 0])
            checking.append((updater, updater.candidates(of: registry)))
        }
        // The oldest copy of each id is sent: the answer then names any version newer than one of the copies.
        var versions: [String: String] = [:]
        for candidate in checking.flatMap(\.candidates)
        where versions[candidate.id].map({ ExtensionUpdateChecker.isNewer($0, than: candidate.version) }) ?? true {
            versions[candidate.id] = candidate.version
        }
        let ids = versions.keys.sorted()
        var latest: [String: String] = [:]
        var unanswered: Set<String> = []
        var reachedService = ids.isEmpty
        var start = 0
        while start < ids.count {
            let batch = ids[start..<min(start + batchSize, ids.count)]
            start += batch.count
            guard let url = ExtensionUpdateChecker.updateCheckURL(extensions: batch.map { ($0, versions[$0] ?? "0") }) else { continue }
            var request = URLRequest(url: url)
            request.setValue(ChromeMasquerade.chromeUserAgent, forHTTPHeaderField: "User-Agent")
            if inBackground {
                request.networkServiceType = .background
                request.allowsConstrainedNetworkAccess = false
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                unanswered.formUnion(batch)
                continue
            }
            reachedService = true
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                unanswered.formUnion(batch)
                continue
            }
            latest.merge(ExtensionUpdateChecker.latestVersions(from: data)) { $1 }
        }
        for (updater, candidates) in checking {
            await updater.finishCheck(candidates: candidates, latest: latest, unanswered: unanswered, reachedService: reachedService)
        }
        return reachedService
    }

    private func candidates(of registry: ProfileExtensionRegistry) -> [(id: String, version: String)] {
        var candidates: [(id: String, version: String)] = registry.loadedExtensions.compactMap { loaded in
            let webExtension = loaded.context.webExtension
            guard isStoreCopy(id: loaded.id, path: loaded.sourcePath, manifest: webExtension.manifest) else { return nil }
            return (loaded.id, webExtension.version ?? "0")
        }
        for stored in registry.disabledStoredExtensions {
            let manifestURL = URL(fileURLWithPath: stored.path).appendingPathComponent("manifest.json")
            let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let manifest, isStoreCopy(id: stored.id, path: stored.path, manifest: manifest) else { continue }
            candidates.append((stored.id, manifest["version"] as? String ?? stored.version))
        }
        return candidates
    }

    private func finishCheck(
        candidates: [(id: String, version: String)], latest: [String: String], unanswered: Set<String>, reachedService: Bool
    ) async {
        guard let registry else { return }
        let previousCheck = status["lastCheck"] ?? 0
        let applies = registry.settingsStore?.get("autoUpdateExtensions") != "false"
        var updated = 0
        var failed = 0
        for candidate in candidates {
            if unanswered.contains(candidate.id) {
                failed += 1
                continue
            }
            guard let version = latest[candidate.id],
                  ExtensionUpdateChecker.isNewer(version, than: candidate.version),
                  registry.access.states[candidate.id]?.declinedUpdateVersion != version else {
                availableUpdates[candidate.id] = nil
                continue
            }
            if !applies {
                availableUpdates[candidate.id] = (candidate.version, version)
                continue
            }
            availableUpdates[candidate.id] = nil
            if await applyUpdate(extensionId: candidate.id, currentVersion: candidate.version, latest: version) {
                updated += 1
            } else if availableUpdates[candidate.id] == nil, registry.access.states[candidate.id]?.declinedUpdateVersion != version {
                failed += 1
            }
        }
        let now = Date().timeIntervalSince1970
        if reachedService { registry.settingsStore?.set(Self.lastCheckKey, value: String(now)) }
        publishStatus([
            "checking": false,
            "lastCheck": reachedService ? now : previousCheck,
            "updated": updated,
            "available": availableUpdates.count,
            "failed": failed
        ])
    }

    func isStoreCopy(id: String, path: String, manifest: [String: Any]?) -> Bool {
        ExtensionFiles.isChromeExtensionId(id) && registry?.files.owns(path) == true
            && ExtensionUpdateChecker.usesGoogleUpdateService(manifest?["update_url"] as? String)
    }

    /// `runtime.requestUpdateCheck`: one check per update interval per extension, as Chrome throttles
    /// it. A newer version installs as an automatic update would, or is listed when those are off.
    func requestUpdateCheck(extensionId: String, now: Date = Date()) async -> [String: Any] {
        if let last = lastRequestedChecks[extensionId], now.timeIntervalSince(last) < Self.checkInterval {
            return ["status": "throttled", "version": ""]
        }
        lastRequestedChecks[extensionId] = now
        let noUpdate: [String: Any] = ["status": "no_update", "version": ""]
        guard let registry, let loaded = registry.loadedExtensions.first(where: { $0.id == extensionId }) else { return noUpdate }
        let webExtension = loaded.context.webExtension
        let current = webExtension.version ?? "0"
        guard isStoreCopy(id: extensionId, path: loaded.sourcePath, manifest: webExtension.manifest),
              let url = ExtensionUpdateChecker.updateCheckURL(extensions: [(extensionId, current)]) else { return noUpdate }
        var request = URLRequest(url: url)
        request.setValue(ChromeMasquerade.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let version = ExtensionUpdateChecker.latestVersions(from: data)[extensionId],
              ExtensionUpdateChecker.isNewer(version, than: current),
              registry.access.states[extensionId]?.declinedUpdateVersion != version else { return noUpdate }
        if registry.settingsStore?.get("autoUpdateExtensions") == "false" {
            availableUpdates[extensionId] = (current, version)
            registry.extensionDidChange(extensionId)
        } else if registry.lifecycle.state(of: extensionId) != .updating(from: current, to: version) {
            Task { await applyUpdate(extensionId: extensionId, currentVersion: current, latest: version) }
        }
        return ["status": "update_available", "version": version]
    }

    /// Installs the update a running extension was told of, now that its worker stopped.
    func applyWaitingUpdate(_ extensionId: String, from current: String) {
        Task {
            guard await applyUpdate(extensionId: extensionId, currentVersion: current, latest: availableUpdates[extensionId]?.latest) else { return }
            availableUpdates[extensionId] = nil
            registry?.notifyExtensionsChanged()
        }
    }

    /// Every row may show a new available version, so all payloads are rebuilt.
    private func publishStatus(_ newStatus: [String: Any]) {
        status = newStatus
        statusChanged = true
        registry?.extensionDidChange(nil)
    }

    /// Applies the newer version the user asked for: one listed while automatic updates are off, or one
    /// whose new permissions were declined, which asks again. True unless the update failed.
    func updateExtension(extensionId: String) async -> Bool {
        guard let registry else { return false }
        let current: String
        if let version = registry.context(for: extensionId)?.webExtension.version {
            current = version
        } else if let stored = try? await registry.extensionStorage.load(id: extensionId) {
            current = stored.version
        } else {
            return false
        }
        let latest = availableUpdates[extensionId]?.latest ?? registry.access.states[extensionId]?.declinedUpdateVersion
        let applied = await applyUpdate(extensionId: extensionId, currentVersion: current, latest: latest, userInitiated: true)
        if applied { availableUpdates[extensionId] = nil }
        registry.extensionDidChange(extensionId)
        return applied || registry.access.states[extensionId]?.declinedUpdateVersion != nil
    }

    /// Downloads (once per `latest`, the version the update service named), verifies and swaps in the new package under the same
    /// id, keeping its storage. An update adding access disables the extension and asks first (a decline is remembered per
    /// version); a package that fails to load rolls back. An update of the extension already under way is waited for: one to
    /// the same version takes its result, one to another version runs after it, as Chrome queues them.
    @discardableResult
    private func applyUpdate(extensionId: String, currentVersion: String, latest: String?, userInitiated: Bool = false) async -> Bool {
        if let running = updatesInFlight[extensionId] {
            let applied = await running.task.value
            guard latest != nil, latest != running.latest else { return applied }
        }
        guard let registry, let directory = registry.files.directory else { return false }
        let update = Task { await registry.files.whileWriting {
            let permanent = directory.appendingPathComponent(extensionId, isDirectory: true)
            let key = "\(extensionId)@\(latest ?? UUID().uuidString)"
            let extracted: URL
            do {
                extracted = try await Self.package(extensionId, key: key)
            } catch {
                Self.logger.error("extension update download failed \(extensionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
            defer {
                Self.packages[key]?.users -= 1
                if Self.runningCheck == nil { Self.prunePackages() }
            }
            let wasEnabled = registry.context(for: extensionId) != nil
            var loadsAfterUpdate = wasEnabled
            do {
                let review = try ExtensionInstallReview.load(from: extracted)  // validate manifest before touching files
                guard ExtensionUpdateChecker.isNewer(review.version, than: currentVersion) else { return false }

                let updated = try await WKWebExtension(resourceBaseURL: extracted)
                let installed: WKWebExtension
                if let loaded = registry.context(for: extensionId)?.webExtension {
                    installed = loaded
                } else {
                    installed = try await WKWebExtension(resourceBaseURL: permanent)
                }
                let added = ExtensionAccess.addedAccess(from: installed, to: updated)
                if !added.permissions.isEmpty || !added.matchPatterns.isEmpty {
                    // A disabled extension is asked when the user requests the update, not from the background.
                    guard wasEnabled || userInitiated else {
                        availableUpdates[extensionId] = (currentVersion, review.version)
                        return false
                    }
                    Self.logger.log("extension update \(extensionId, privacy: .public) requests new access; disabled until accepted")
                    await registry.disable(extensionId: extensionId)
                    let prompt = ExtensionInstallReview(name: review.name, version: review.version, permissions: added.permissions, hostPermissions: added.matchPatterns)
                    guard prompt.confirmPermissionIncrease() else {
                        await registry.access.update(extensionId) { $0.declinedUpdateVersion = review.version }
                        return false
                    }
                    loadsAfterUpdate = true
                } else if wasEnabled, !userInitiated,
                          registry.lifecycle.updateFound(extensionId, from: currentVersion, to: review.version, manifest: updated.manifest) {
                    // As in Chrome, an extension in use is told and updated once its worker is idle; a
                    // runtime.reload() stops it at once.
                    availableUpdates[extensionId] = (currentVersion, review.version)
                    return false
                }

                try await registry.files.replace(
                    extensionId,
                    with: extracted,
                    beforeSwap: {
                        if registry.context(for: extensionId) != nil { await registry.unload(extensionId: extensionId, removePersistedRecord: false) }
                    },
                    install: { installed in
                        if loadsAfterUpdate {
                            try await registry.load(from: installed, extensionId: extensionId, as: .update(from: currentVersion))
                        } else {
                            registry.lifecycle.updatedWhileDisabled(extensionId, from: currentVersion)
                            try await registry.storeDisabledRecord(id: extensionId, name: review.name, version: review.version, path: installed.path)
                        }
                    },
                    rollback: { previous in
                        if wasEnabled { try? await registry.load(from: previous, extensionId: extensionId) }
                    }
                )
                if registry.access.states[extensionId]?.declinedUpdateVersion != nil {
                    await registry.access.update(extensionId) { $0.declinedUpdateVersion = nil }
                }
                lastRequestedChecks[extensionId] = nil
                Self.logger.log("extension updated \(extensionId, privacy: .public) to \(review.version, privacy: .public)")
                return true
            } catch {
                Self.logger.error("extension update failed \(extensionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        } }
        updatesInFlight[extensionId] = (latest, update)
        let applied = await update.value
        if updatesInFlight[extensionId]?.task == update { updatesInFlight[extensionId] = nil }
        return applied
    }

    /// The extracted package `key` names, downloaded unless an update already did. Its caller releases its use.
    private static func package(_ extensionId: String, key: String) async throws -> URL {
        let download = packages[key]?.download ?? Task { try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: extensionId) }
        packages[key] = (download, (packages[key]?.users ?? 0) + 1)
        do {
            return try await download.value
        } catch {
            // The next attempt downloads again.
            if packages[key]?.download == download { packages[key] = nil }
            throw error
        }
    }

    /// Deletes the packages no update uses or waits for.
    private static func prunePackages() {
        let waiting = Set(updaters.allObjects.flatMap { updater in updater.availableUpdates.map { "\($0.key)@\($0.value.latest)" } })
        for (key, package) in packages where package.users <= 0 && !waiting.contains(key) {
            packages[key] = nil
            Task.detached(priority: .utility) {
                guard let extracted = try? await package.download.value else { return }
                try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent())
            }
        }
    }
}
