import Foundation
import GRDB

struct SitePermission: Sendable, Identifiable, Equatable {
    let id: UUID
    let origin: String
    let type: String
    let decision: String
    let updatedAt: Date

    var bridgeData: [String: Any] {
        [
            "id": id.uuidString,
            "origin": origin,
            "type": type,
            "decision": decision,
            "updatedAt": updatedAt.timeIntervalSince1970
        ]
    }
}

private struct SitePermissionRecord: Sendable, Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sitePermissions"

    let id: UUID
    var origin: String
    var type: String
    var decision: String
    var updatedAt: Date

    init(id: UUID = UUID(), origin: String, type: String, decision: String, updatedAt: Date = Date()) {
        self.id = id; self.origin = origin; self.type = type; self.decision = decision; self.updatedAt = updatedAt
    }

    fileprivate enum Columns: String, ColumnExpression {
        case id, origin, type, decision, updatedAt
    }

    var permission: SitePermission {
        SitePermission(id: id, origin: origin, type: type, decision: decision, updatedAt: updatedAt)
    }
}

@MainActor
final class SitePermissionStore {

    private let dbPool: DatabasePool

    /// In-memory mirror of the tiny, rarely-written table: `decision` backs
    /// navigator.permissions.query and permission prompts, which must not pay a synchronous
    /// SQLite round trip per call (the same reasoning behind SettingsStore's mirror).
    private var decisionsByOrigin: [String: [String: String]] = [:]
    private var locationById: [UUID: (origin: String, type: String)] = [:]
    private var mirrorLoaded = false

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    private func loadMirrorIfNeeded() {
        guard !mirrorLoaded else { return }
        // A failed read keeps the mirror unloaded so the next call retries instead of silently
        // running with every stored decision missing.
        loggingPersistenceError("sitePermission.load") {
            let records = try dbPool.read { db in try SitePermissionRecord.fetchAll(db) }
            for record in records {
                decisionsByOrigin[record.origin, default: [:]][record.type] = record.decision
                locationById[record.id] = (record.origin, record.type)
            }
            mirrorLoaded = true
        }
    }

    func decision(forOrigin origin: String, type: String) -> Bool? {
        loadMirrorIfNeeded()
        let normalizedOrigin = normalizeOrigin(origin)
        let normalizedTypes = normalizeTypes(type)

        let byType = decisionsByOrigin[normalizedOrigin] ?? [:]
        if normalizedTypes.contains(where: { byType[$0] == "deny" }) { return false }
        return normalizedTypes.allSatisfy { byType[$0] == "allow" } ? true : nil
    }

    func upsert(origin: String, type: String, granted: Bool) {
        let normalizedOrigin = normalizeOrigin(origin)
        let normalizedTypes = normalizeTypes(type)
        let decision = granted ? "allow" : "deny"

        loggingPersistenceError("sitePermission.upsert") {
            let touchedIdsByType = try dbPool.write { db in
                var touchedIdsByType: [(type: String, id: UUID)] = []
                for normalizedType in normalizedTypes {
                    if var existing = try SitePermissionRecord
                        .filter(SitePermissionRecord.Columns.origin == normalizedOrigin)
                        .filter(SitePermissionRecord.Columns.type == normalizedType)
                        .fetchOne(db) {
                        existing.decision = decision; existing.updatedAt = Date()
                        try existing.update(db)
                        touchedIdsByType.append((normalizedType, existing.id))
                    } else {
                        let record = SitePermissionRecord(origin: normalizedOrigin, type: normalizedType, decision: decision)
                        try record.insert(db)
                        touchedIdsByType.append((normalizedType, record.id))
                    }
                }
                return touchedIdsByType
            }
            for (normalizedType, id) in touchedIdsByType {
                decisionsByOrigin[normalizedOrigin, default: [:]][normalizedType] = decision
                locationById[id] = (normalizedOrigin, normalizedType)
            }
        }
    }

    func allPermissions() -> [SitePermission] {
        var permissions: [SitePermission] = []
        loggingPersistenceError("sitePermission.all") {
            permissions = try dbPool.read { db in
                try SitePermissionRecord
                    .order(SitePermissionRecord.Columns.updatedAt.desc)
                    .fetchAll(db)
                    .map(\.permission)
            }
        }
        return permissions
    }

    /// Returns the origin and type the revoked decision was for.
    @discardableResult
    func revoke(id: UUID) -> (origin: String, type: String)? {
        loadMirrorIfNeeded()
        var revoked: (origin: String, type: String)?
        loggingPersistenceError("sitePermission.revoke") {
            _ = try dbPool.write { db in try SitePermissionRecord.deleteOne(db, id: id) }
            if let location = locationById.removeValue(forKey: id) {
                decisionsByOrigin[location.origin]?[location.type] = nil
                revoked = location
            }
        }
        return revoked
    }

    func clearAll() {
        loggingPersistenceError("sitePermission.clearAll") {
            _ = try dbPool.write { db in try SitePermissionRecord.deleteAll(db) }
            decisionsByOrigin.removeAll()
            locationById.removeAll()
        }
    }

    private func normalizeOrigin(_ origin: String) -> String { origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private func normalizeTypes(_ type: String) -> [String] {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedType == "camera and microphone" ? ["camera", "microphone"] : [normalizedType]
    }
}
