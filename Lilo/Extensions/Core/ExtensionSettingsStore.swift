import Foundation
import GRDB

/// The settings a profile's extensions control (chrome.proxy, chrome.fontSettings,
/// chrome.contentSettings) and their instance IDs, kept per extension as Chrome keeps them: they outlive
/// a relaunch and a disable, and go with an uninstall. Values are JSON objects, arrays, strings or numbers.
@MainActor
final class ExtensionSettingsStore {
    private let pool: DatabasePool
    /// extensionId -> key -> value, read once: the table holds a few rows per extension.
    private var values: [String: [String: Any]]?
    nonisolated(unsafe) private var unloadObserver: Any?

    init(pool: DatabasePool, profileId: UUID) {
        self.pool = pool
        unloadObserver = NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["uninstalled"] as? Bool == true, note.userInfo?["profileId"] as? UUID == profileId,
                  let extensionId = note.userInfo?["extensionId"] as? String else { return }
            MainActor.assumeIsolated { self?.removeAll(extensionId: extensionId) }
        }
    }

    deinit {
        unloadObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    private func loaded() -> [String: [String: Any]] {
        if let values { return values }
        var read: [String: [String: Any]] = [:]
        loggingPersistenceError("extensionSettings.load") {
            for row in try pool.read({ try Row.fetchAll($0, sql: "SELECT extensionId, key, value FROM extensionSettings") }) {
                let json: String = row["value"]
                guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) else { continue }
                read[row["extensionId"], default: [:]][row["key"]] = value
            }
        }
        values = read
        return read
    }

    func value(_ key: String, extensionId: String) -> Any? {
        loaded()[extensionId]?[key]
    }

    /// A nil value removes the extension's setting.
    func set(_ key: String, extensionId: String, to value: Any?) {
        var all = loaded()
        all[extensionId, default: [:]][key] = value
        values = all
        loggingPersistenceError("extensionSettings.set") {
            try pool.write { db in
                if let value {
                    let json = String(bytes: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), encoding: .utf8)
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO extensionSettings (extensionId, key, value) VALUES (?, ?, ?)",
                        arguments: [extensionId, key, json]
                    )
                } else {
                    try db.execute(sql: "DELETE FROM extensionSettings WHERE extensionId = ? AND key = ?", arguments: [extensionId, key])
                }
            }
        }
    }

    /// The extension of `loadedIds` whose value for `key` applies: Chrome gives a setting to the
    /// extension installed last, Lilo to the one loaded last.
    func controller(of key: String, among loadedIds: [String]) -> String? {
        let all = loaded()
        return loadedIds.last { all[$0]?[key] != nil }
    }

    /// Every key starting with `prefix` that some extension sets.
    func keys(withPrefix prefix: String) -> Set<String> {
        Set(loaded().values.flatMap { $0.keys.filter { $0.hasPrefix(prefix) } })
    }

    /// Chrome's `levelOfControl` of `key` for the extension: only an extension that takes precedence
    /// over it (loaded after it) keeps it from setting the value.
    func levelOfControl(of key: String, for extensionId: String, among loadedIds: [String]) -> String {
        switch controller(of: key, among: loadedIds) {
        case extensionId: return "controlled_by_this_extension"
        case let other?
            where (loadedIds.firstIndex(of: other) ?? 0) > (loadedIds.firstIndex(of: extensionId) ?? loadedIds.count):
            return "controlled_by_other_extensions"
        default: return "controllable_by_this_extension"
        }
    }

    private func removeAll(extensionId: String) {
        guard loaded()[extensionId] != nil else { return }
        values?[extensionId] = nil
        loggingPersistenceError("extensionSettings.removeAll") {
            try pool.write { try $0.execute(sql: "DELETE FROM extensionSettings WHERE extensionId = ?", arguments: [extensionId]) }
        }
    }
}
