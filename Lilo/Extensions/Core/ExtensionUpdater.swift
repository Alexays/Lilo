import Foundation
import WebKit
import os

/// Updates one profile's Chrome Web Store extensions: periodic and requested checks against Google's
/// update service, then the download, review and swap of each newer version, keeping the extension's
/// id and so its storage.
@MainActor
final class ExtensionUpdater {
    private static let logger = Logger(liloCategory: "extension-updater")

    /// Chrome checks about every five hours.
    static let checkInterval: TimeInterval = 5 * 60 * 60
    /// Extensions per update-check request, keeping the GET URL well under server limits.
    private static let batchSize = 25

    /// Weak: the registry owns the updater. Each method holds it for its whole run.
    private weak var registry: ProfileExtensionRegistry?
    /// Weak-self loop: it ends once the updater is released.
    private var checkTask: Task<Void, Never>?
    /// Newer versions a check found while automatic updates are off, applied from the Update button.
    private(set) var availableUpdates: [String: (current: String, latest: String)] = [:]
    /// Outcome of the last check, sent to the settings page alongside the extension payloads.
    private(set) var status: [String: Any] = [:]
    /// Set when `status` changed since the extensions panel last heard.
    var statusChanged = false
    /// When each extension last called `runtime.requestUpdateCheck`.
    private var lastRequestedChecks: [String: Date] = [:]

    /// When this profile's last check finished, kept across launches.
    private let lastCheckKey: String

    init(registry: ProfileExtensionRegistry) {
        self.registry = registry
        lastCheckKey = "extensionUpdateLastCheck.\(registry.profileId.uuidString)"
    }

    /// Idempotent. The interval spans launches, and the first pass waits at least 90s so it does not
    /// compete with launch.
    func start(
        now: Date = Date(),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        guard checkTask == nil, let registry else { return }
        let lastCheck = registry.settingsStore?.get(lastCheckKey).flatMap(TimeInterval.init) ?? 0
        if lastCheck > 0, status.isEmpty {
            status = ["lastCheck": lastCheck]
            statusChanged = true
            registry.notifyExtensionsChanged()
        }
        let remaining = Self.checkInterval - (now.timeIntervalSince1970 - lastCheck)
        checkTask = Task { [weak self] in
            await sleep(.seconds(max(90, min(Self.checkInterval, remaining))))
            while !Task.isCancelled {
                guard self != nil else { break }
                // Under constrained power the network pass is skipped; the next tick retries.
                if !HiddenSpaceLifecycleController.systemIsPowerConstrained() {
                    await self?.checkForUpdates()
                }
                await sleep(.seconds(Self.checkInterval))
            }
        }
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    /// Checks every Web Store extension, enabled or not, with Google's update service in batches, applying or only listing newer
    /// versions per the auto-update setting. Only copies under Lilo's extensions directory qualify: unpacked folders are never replaced.
    func checkForUpdates() async {
        guard let registry, registry.files.directory != nil, status["checking"] as? Bool != true else { return }
        let applies = registry.settingsStore?.get("autoUpdateExtensions") != "false"
        var updated = 0
        var failed = 0
        publishStatus(["checking": true, "lastCheck": status["lastCheck"] ?? 0])
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

        var start = 0
        while start < candidates.count {
            let batch = Array(candidates[start..<min(start + Self.batchSize, candidates.count)])
            start += batch.count
            guard let url = ExtensionUpdateChecker.updateCheckURL(extensions: batch) else { continue }
            var request = URLRequest(url: url)
            request.setValue(ChromeMasquerade.chromeUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                failed += batch.count
                continue
            }
            let latest = ExtensionUpdateChecker.latestVersions(from: data)
            for candidate in batch {
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
                if await applyUpdate(extensionId: candidate.id, currentVersion: candidate.version) {
                    updated += 1
                } else if availableUpdates[candidate.id] == nil, registry.access.states[candidate.id]?.declinedUpdateVersion != version {
                    failed += 1
                }
            }
        }
        let now = Date().timeIntervalSince1970
        registry.settingsStore?.set(lastCheckKey, value: String(now))
        publishStatus([
            "checking": false,
            "lastCheck": now,
            "updated": updated,
            "available": availableUpdates.count,
            "failed": failed
        ])
    }

    private func isStoreCopy(id: String, path: String, manifest: [String: Any]?) -> Bool {
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
            Task { await applyUpdate(extensionId: extensionId, currentVersion: current) }
        }
        return ["status": "update_available", "version": version]
    }

    /// Installs the update a running extension was told of, now that its worker stopped.
    func applyWaitingUpdate(_ extensionId: String, from current: String) {
        Task {
            guard await applyUpdate(extensionId: extensionId, currentVersion: current) else { return }
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
        let applied = await applyUpdate(extensionId: extensionId, currentVersion: current, userInitiated: true)
        if applied { availableUpdates[extensionId] = nil }
        registry.extensionDidChange(extensionId)
        return applied || registry.access.states[extensionId]?.declinedUpdateVersion != nil
    }

    /// Downloads, verifies and swaps in the new package under the same id, keeping its storage. An update adding access disables the
    /// extension and asks first (a decline is remembered per version); a package that fails to load rolls back.
    @discardableResult
    private func applyUpdate(extensionId: String, currentVersion: String, userInitiated: Bool = false) async -> Bool {
        guard let registry, let directory = registry.files.directory else { return false }
        return await registry.files.whileWriting {
            let fm = FileManager.default
            let permanent = directory.appendingPathComponent(extensionId, isDirectory: true)
            let extracted: URL
            do {
                extracted = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: extensionId)
            } catch {
                Self.logger.error("extension update download failed \(extensionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
            defer { try? fm.removeItem(at: extracted.deletingLastPathComponent()) }
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
        }
    }
}
