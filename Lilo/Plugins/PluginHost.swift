import Foundation
import PluginCore

/// The mac lane's plugin runtime: owns the registry scan, one lazy `PluginSession` per enabled
/// plugin, and the persisted enabled state, capability grants and setting values the panel edits.
/// A session object is not a process — the sidecar spawns on the first call and a deadline miss
/// or exit leaves the plugin enabled, respawning on the next call.
@MainActor
final class PluginHost {
    /// User plugins land in app support; bundled ones ship in the app bundle's `Plugins` folder.
    static let defaultUserRoot = URL(fileURLWithPath: BuildIdentity.appSupportDirectory, isDirectory: true)
        .appendingPathComponent("Plugins", isDirectory: true)
    static let defaultSupportRoot = URL(fileURLWithPath: BuildIdentity.appSupportDirectory, isDirectory: true)
        .appendingPathComponent("Plugin Support", isDirectory: true)

    /// The panel asks for fresh rows after any of these.
    var onChanged: (() -> Void)?

    private let registry: PluginRegistry
    private weak var settingsStore: SettingsStore?
    private let secrets: any PluginSecretStore
    private let tabs: PluginTabsAdapter
    private var sessions: [String: PluginSession] = [:]
    private var records: [PluginRecord] = []

    init(settingsStore: SettingsStore, registry: PluginRegistry, secrets: any PluginSecretStore, tabs: PluginTabsAdapter = PluginTabsAdapter()) {
        self.tabs = tabs
        self.settingsStore = settingsStore
        self.registry = registry
        self.secrets = secrets
    }

    convenience init(
        settingsStore: SettingsStore, secrets: any PluginSecretStore = KeychainPluginSecretStore(),
        tabs: PluginTabsAdapter = PluginTabsAdapter()
    ) {
        var roots = [PluginRegistry.Root(url: Self.defaultUserRoot, bundled: false)]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) {
            roots.append(PluginRegistry.Root(url: bundled, bundled: true))
        }
        self.init(
            settingsStore: settingsStore,
            registry: PluginRegistry(roots: roots, supportRoot: Self.defaultSupportRoot),
            secrets: secrets,
            tabs: tabs
        )
    }

    /// Rescans the plugin roots; sessions whose folder changed or vanished drop so the next call
    /// spawns a sidecar on the new manifest.
    @discardableResult
    func refresh() async -> PluginRegistry.ScanResult {
        let result = await registry.rescan()
        records = result.records
        let foldersByID = Dictionary(records.map { ($0.id, $0.folder) }, uniquingKeysWith: { first, _ in first })
        for (id, session) in sessions {
            let stale = foldersByID[id].map { result.changedFolders.contains($0) } ?? true
            if stale {
                await session.stop()
                sessions.removeValue(forKey: id)
            }
        }
        if result.changed { onChanged?() }
        return result
    }

    // MARK: - Panel mutations

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let store = settingsStore else { return }
        var ids = store.enabledPluginIDs
        if enabled { ids.insert(id) } else { ids.remove(id) }
        store.enabledPluginIDs = ids
        if !enabled {
            Task { await sessions[id]?.stop() }
            sessions.removeValue(forKey: id)
        }
    }

    /// A UI-set setting: password types land in the Keychain, the rest in the settings table.
    func setSetting(name: String, value: JSONValue, for id: String) {
        guard let store = settingsStore else { return }
        if settingSpec(named: name, in: record(id: id))?.type == .password {
            if case .string(let secret) = value { try? secrets.setSecret(secret, for: id, name: name) }
            return
        }
        storeSettingValue(value, named: name, for: id)
    }

    func revokeCapability(_ capability: String, for id: String) {
        guard let store = settingsStore, let record = record(id: id),
              let manifest = record.manifest else { return }
        let remaining = grantedCapabilities(for: record).filter { $0.rawValue != capability }
        var grants = store.pluginCapabilityGrants
        grants[id] = remaining.count == manifest.capabilities.count ? nil : remaining.map(\.rawValue)
        store.pluginCapabilityGrants = grants
    }

    func stop(id: String) async {
        await sessions[id]?.stop()
    }

    func folderURL(for id: String) -> URL? {
        record(id: id)?.folder
    }

    // MARK: - Rows

    /// `BridgePluginRow` dictionaries, one per scanned plugin folder.
    func pluginRows() async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for record in records {
            rows.append(await row(for: record))
        }
        return rows
    }

    private func row(for record: PluginRecord) async -> [String: Any] {
        let manifest = record.manifest
        var settings: [[String: Any]] = []
        var settingValues: [String: Any] = [:]
        for spec in manifest?.contributes.settings ?? [] {
            var specDict: [String: Any] = [
                "name": spec.name, "type": spec.type.rawValue, "title": spec.title
            ]
            if let options = spec.options { specDict["options"] = options }
            if let fallback = spec.default { specDict["default"] = fallback.anyObject }
            if let required = spec.required { specDict["required"] = required }
            settings.append(specDict)
            if spec.type == .password {
                // The value never leaves the Keychain; the panel only learns that one exists.
                settingValues[spec.name] = (try? secrets.secret(for: record.id, name: spec.name)) != nil ? "********" : ""
            } else if let value = settingsStore?.pluginSettingValues[record.id]?[spec.name] {
                settingValues[spec.name] = value.anyObject
            }
        }
        let running = await sessions[record.id]?.isRunning ?? false
        var row: [String: Any] = [
            "id": record.id,
            "title": manifest?.title ?? record.id,
            "version": manifest?.version ?? "",
            "enabled": isEnabled(record),
            "running": running,
            "capabilities": (manifest?.capabilities ?? []).map(\.rawValue),
            "grantedCapabilities": grantedCapabilities(for: record).map(\.rawValue),
            "settings": settings,
            "settingValues": settingValues,
            "supportDir": record.supportDirectory.path
        ]
        if let icon = record.iconDataURL { row["icon"] = icon }
        if let reason = record.rejectionReason { row["rejectionReason"] = reason }
        return row
    }

    private func isEnabled(_ record: PluginRecord) -> Bool {
        record.valid && (settingsStore?.enabledPluginIDs.contains(record.id) ?? false)
    }

    private func grantedCapabilities(for record: PluginRecord) -> [PluginCapability] {
        let declared = record.manifest?.capabilities ?? []
        guard let stored = settingsStore?.pluginCapabilityGrants[record.id] else { return declared }
        let granted = Set(stored)
        return declared.filter { granted.contains($0.rawValue) }
    }

    func record(id: String) -> PluginRecord? {
        records.first { $0.id == id }
    }

    private func settingSpec(named name: String, in record: PluginRecord?) -> PluginManifest.Setting? {
        record?.manifest?.contributes.settings.first { $0.name == name }
    }

    // MARK: - Sessions and the host-ward gate

    /// The enabled plugin's session, configured against its grants. Sidecars spawn lazily.
    func session(for id: String) async -> PluginSession? {
        guard let record = record(id: id), record.valid, isEnabled(record), let manifest = record.manifest else { return nil }
        if let session = sessions[id] { return session }
        let session = PluginSession(manifest: manifest, pluginRoot: record.folder)
        let api = hostAPI(for: record)
        await session.set(onRequest: { method, params in
            await api.handle(method, params: params)
        }, onExit: { [weak self] in
            Task { @MainActor in self?.onChanged?() }
        })
        sessions[id] = session
        return session
    }

    /// Plugin→host calls go through `PluginHostAPI`, which maps every method to one capability and
    /// answers `capabilityNotGranted` without the grant. Grants are read per call, so a revoke
    /// takes effect on a running sidecar's next request.
    func hostAPI(for record: PluginRecord) -> PluginHostAPI {
        let id = record.id
        return PluginHostAPI(
            pluginID: id, supportDirectory: record.supportDirectory, secrets: secrets,
            adapters: PluginHostAdapters(
                listTabs: { [tabs] in await MainActor.run { tabs.list() } },
                openTab: { [tabs] url in await MainActor.run { tabs.open(url) } },
                settingValues: { [weak self] _ in await self?.settingsStore?.pluginSettingValues[id] ?? [:] },
                setSettingValue: { [weak self] _, name, value in await self?.storeSettingValue(value, named: name, for: id) }
            ),
            granted: { [weak self] in await self?.grantedSet(for: id) ?? [] }
        )
    }

    private func grantedSet(for id: String) -> Set<PluginCapability> {
        record(id: id).map { Set(grantedCapabilities(for: $0)) } ?? []
    }

    private func storeSettingValue(_ value: JSONValue, named name: String, for id: String) {
        guard let store = settingsStore else { return }
        var values = store.pluginSettingValues
        var plugin = values[id] ?? [:]
        plugin[name] = value
        values[id] = plugin
        store.pluginSettingValues = values
    }
}
