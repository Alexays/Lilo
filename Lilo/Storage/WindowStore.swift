import AppKit
import GRDB
import os

/// A browser window as it reopens at the next launch.
struct StoredWindow: Equatable, Sendable {
    var frame: NSRect
    var spaceId: UUID?
}

/// The open windows, in the order they opened, in the global database.
@MainActor
final class WindowStore {
    nonisolated private static let logger = Logger(liloCategory: "storage")
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Read off the main actor with the rest of the startup snapshot.
    nonisolated static func load(_ db: Database) throws -> [StoredWindow] {
        try Row.fetchAll(db, sql: "SELECT frame, spaceId FROM windows ORDER BY sortOrder").map { row in
            StoredWindow(
                frame: NSRectFromString(row["frame"]),
                spaceId: (row["spaceId"] as String?).flatMap(UUID.init(uuidString:))
            )
        }
    }

    /// The rows last written, so a save that changes nothing (most space switches) skips the
    /// transaction. Weak pool: a cache left by a closed database never matches a new one.
    private static weak var lastWrittenPool: DatabasePool?
    private static var lastWritten: [StoredWindow] = []

    func replaceAll(_ windows: [StoredWindow]) throws {
        if Self.lastWrittenPool === dbPool, Self.lastWritten == windows { return }
        try dbPool.write { try Self.write(windows, $0) }
        Self.lastWrittenPool = dbPool
        Self.lastWritten = windows
    }

    /// Off the main thread: window moves and space switches save often.
    func replaceAllInBackground(_ windows: [StoredWindow]) {
        if Self.lastWrittenPool === dbPool, Self.lastWritten == windows { return }
        // Recorded at enqueue: the writer queue applies saves in order, so the last one enqueued wins.
        Self.lastWrittenPool = dbPool
        Self.lastWritten = windows
        dbPool.asyncWrite({ try Self.write(windows, $0) }, completion: { _, result in
            if case let .failure(error) = result {
                Self.logger.error("windows save failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in Self.lastWrittenPool = nil }
            }
        })
    }

    nonisolated private static func write(_ windows: [StoredWindow], _ db: Database) throws {
        try db.execute(sql: "DELETE FROM windows")
        for (index, window) in windows.enumerated() {
            try db.execute(
                sql: "INSERT INTO windows (sortOrder, frame, spaceId) VALUES (?, ?, ?)",
                arguments: [index, NSStringFromRect(window.frame), window.spaceId?.uuidString]
            )
        }
    }
}
