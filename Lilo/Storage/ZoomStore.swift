import Foundation
import GRDB
import os
import WebKit

private let zoomLogger = Logger(liloCategory: "storage")

/// Persists per-site zoom levels in a profile database. A private space keeps its own levels in memory
/// over the profile's, as Chrome's incognito does.
@MainActor
final class ZoomStore {

    private var dbPool: DatabasePool?
    private var zoomLevels: [String: Double] = [:]
    /// Keyed weakly by each private space's data store, so a space's levels go with it.
    private let privateZoomLevels = NSMapTable<WKWebsiteDataStore, NSMutableDictionary>.weakToStrongObjects()

    func useDatabase(_ dbPool: DatabasePool) {
        self.dbPool = dbPool
        zoomLevels = loadZoomLevels(from: dbPool)
    }

    /// The profile keeps only a level other than the default; a private space keeps any, over the profile's.
    func setZoom(_ zoom: Double, forHost host: String, default defaultZoom: Double, of engine: WKWebViewTab) {
        guard let normalizedHost = normalizeHost(host) else { return }
        if engine.isPrivateBrowsing {
            let store = engine.wkWebView.configuration.websiteDataStore
            let levels = privateZoomLevels.object(forKey: store) ?? NSMutableDictionary()
            levels[normalizedHost] = zoom
            privateZoomLevels.setObject(levels, forKey: store)
        } else if abs(zoom - defaultZoom) < 0.01 {
            removeZoom(forHost: host)
        } else {
            zoomLevels[normalizedHost] = zoom
            persistZoom(zoom, forHost: normalizedHost)
        }
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
        guard let host = url?.host.flatMap(normalizeHost) else {
            engine.setPageZoom(defaultZoom)
            return
        }
        let privateZoom = engine.isPrivateBrowsing
            ? privateZoomLevels.object(forKey: engine.wkWebView.configuration.websiteDataStore)?[host] as? Double : nil
        engine.setPageZoom(privateZoom ?? zoomLevels[host] ?? defaultZoom)
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
