import Foundation
import GRDB
import os

private let zoomLogger = Logger(liloCategory: "storage")

/// Persists per-site zoom levels in a profile database.
@MainActor
final class ZoomStore {

    private var dbPool: DatabasePool?
    private var zoomLevels: [String: Double] = [:]

    func useDatabase(_ dbPool: DatabasePool) {
        self.dbPool = dbPool
        zoomLevels = loadZoomLevels(from: dbPool)
    }

    /// Only a level other than the default is kept for a host.
    func setZoom(_ zoom: Double, forHost host: String, default defaultZoom: Double) {
        if abs(zoom - defaultZoom) < 0.01 {
            removeZoom(forHost: host)
            return
        }
        guard let normalizedHost = normalizeHost(host) else { return }
        zoomLevels[normalizedHost] = zoom
        persistZoom(zoom, forHost: normalizedHost)
    }

    /// Every host with a stored zoom, keyed by normalized host.
    var allZoomLevels: [String: Double] { zoomLevels }

    /// Remove zoom for a host (reset to default).
    func removeZoom(forHost host: String) {
        guard let normalizedHost = normalizeHost(host) else { return }
        zoomLevels.removeValue(forKey: normalizedHost)
        persistRemoval(forHost: normalizedHost)
    }

    /// Apply the stored zoom level to a tab's engine.
    func applyZoom(to engine: WKWebViewTab, forURL url: URL?, default defaultZoom: Double = 1.0) {
        guard let host = url?.host, !host.isEmpty else {
            engine.setPageZoom(defaultZoom)
            return
        }
        engine.setPageZoom(zoomLevels[normalizeHost(host) ?? host] ?? defaultZoom)
    }

    private func normalizeHost(_ host: String) -> String? {
        let n = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n.isEmpty ? nil : n
    }

    private func loadZoomLevels(from dbPool: DatabasePool) -> [String: Double] {
        do {
            return try dbPool.read { db in
                var result: [String: Double] = [:]
                let rows = try Row.fetchAll(db, sql: "SELECT host, zoom FROM zoomLevels")
                for row in rows {
                    guard let host = row["host"] as String?, let normalizedHost = normalizeHost(host),
                          let zoom = row["zoom"] as Double? else { continue }

                    result[normalizedHost] = zoom
                }
                return result
            }
        } catch {
            zoomLogger.error("zoom load failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    // Memory is already updated by the callers; the row lands on the writer queue off the main
    // actor, the same way SpaceManager.setActiveTab persists an activation.
    private func persistZoom(_ zoom: Double, forHost host: String) {
        dbPool?.asyncWrite({ db in
            try db.execute(sql: "INSERT OR REPLACE INTO zoomLevels (host, zoom) VALUES (?, ?)", arguments: [host, zoom])
        }, completion: { _, result in
            if case .failure(let error) = result {
                zoomLogger.error("zoom save failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    private func persistRemoval(forHost host: String) {
        dbPool?.asyncWrite({ db in
            try db.execute(sql: "DELETE FROM zoomLevels WHERE host = ?", arguments: [host])
        }, completion: { _, result in
            if case .failure(let error) = result {
                zoomLogger.error("zoom removal failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }
}
