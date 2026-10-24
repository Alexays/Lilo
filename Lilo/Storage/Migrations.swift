import Foundation
import GRDB

/// Current schema for Lilo databases.
enum Migrations {

    /// Create the global database schema (profile metadata and app-wide state).
    static func migrateGlobal(_ db: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "profiles") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "Default")
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("color", .text).notNull().defaults(to: Profile.palette[0])
            }

            try db.create(table: "appState") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }

            try db.create(table: "settings") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }

            try db.create(table: "spaces") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "New Space")
                t.column("icon", .text).notNull().defaults(to: "🌐")
                t.column("color", .text).notNull().defaults(to: "#5865f2")
                t.column("profileId", .text).notNull()
                t.column("isPrivate", .boolean).notNull().defaults(to: false)
                t.column("activeTabId", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("archiveAfterHours", .integer).notNull().defaults(to: 12)
            }
            try db.create(index: "idx_spaces_profileId", on: "spaces", columns: ["profileId"])
            try db.create(index: "idx_spaces_sortOrder", on: "spaces", columns: ["sortOrder"], unique: true)

            try db.create(table: "sitePermissions") { t in
                t.primaryKey("id", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("type", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_sitePermissions_origin_type", on: "sitePermissions", columns: ["origin", "type"], unique: true)
            try db.create(index: "idx_sitePermissions_updatedAt", on: "sitePermissions", columns: ["updatedAt"])

            try db.create(table: "installed_extensions") { t in
                t.column("id", .text).notNull()
                t.column("profile_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("version", .text).notNull()
                t.column("enabled", .integer).notNull().defaults(to: 1)
                t.column("install_type", .text).notNull().defaults(to: "normal")
                t.column("install_date", .datetime).notNull().defaults(to: "CURRENT_TIMESTAMP")
                t.column("path", .text).notNull()
                t.column("site_access", .text).notNull().defaults(to: "")
                t.primaryKey(["id", "profile_id"])
                t.foreignKey(["profile_id"], references: "profiles", columns: ["id"], onDelete: .cascade)
            }
            try db.create(index: "idx_installed_extensions_profile_id", on: "installed_extensions", columns: ["profile_id"])

            try db.create(table: "windows") { t in
                t.column("sortOrder", .integer).primaryKey()
                t.column("frame", .text).notNull()
                t.column("spaceId", .text)
            }
        }

        try migrator.migrate(db)
    }

    /// Create a per-profile database schema (history, extensions, downloads and tabs state).
    static func migrateProfile(_ db: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "zoomLevels") { t in
                t.primaryKey("host", .text).notNull()
                t.column("zoom", .double).notNull().defaults(to: 1.0)
            }

            try db.create(table: "history") { t in
                t.primaryKey("id", .text).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("visitCount", .integer).notNull().defaults(to: 1)
                t.column("lastVisitedAt", .datetime).notNull()
                t.column("openedFrom", .text)
            }
            try db.create(index: "idx_history_url", on: "history", columns: ["url"], unique: true)
            // The omnibox "recent" sorts; create(index:) can't express DESC.
            try db.execute(sql: """
                CREATE INDEX idx_history_visitCount_lastVisitedAt
                ON history(visitCount DESC, lastVisitedAt DESC)
                """)
            try db.execute(sql: "CREATE INDEX idx_history_lastVisitedAt ON history(lastVisitedAt DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE historyFts USING fts5(
                    url,
                    title,
                    content='history',
                    content_rowid='rowid'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
                    INSERT INTO historyFts(rowid, url, title)
                    VALUES (new.rowid, new.url, new.title);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER history_ad AFTER DELETE ON history BEGIN
                    INSERT INTO historyFts(historyFts, rowid, url, title)
                    VALUES ('delete', old.rowid, old.url, old.title);
                END
                """)
            // Only url and title are indexed, so a revisit that bumps visitCount and lastVisitedAt
            // must not re-tokenize the FTS row.
            try db.execute(sql: """
                CREATE TRIGGER history_au AFTER UPDATE ON history
                WHEN old.url IS NOT new.url OR old.title IS NOT new.title
                BEGIN
                    INSERT INTO historyFts(historyFts, rowid, url, title)
                    VALUES ('delete', old.rowid, old.url, old.title);
                    INSERT INTO historyFts(rowid, url, title)
                    VALUES (new.rowid, new.url, new.title);
                END
                """)

            try db.create(table: "appState") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }

            try db.create(table: "chromeBookmarks") { t in
                t.column("id", .text).primaryKey()
                t.column("parentId", .text)
                t.column("index_", .integer)
                t.column("url", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("dateAdded", .integer)
                t.column("dateGroupModified", .integer)
            }
            try db.create(index: "idx_chromeBookmarks_parentId", on: "chromeBookmarks", columns: ["parentId"])
            try db.execute(sql: """
                INSERT INTO chromeBookmarks (id, parentId, index_, title) VALUES
                    ('0', NULL, NULL, 'Bookmarks'),
                    ('1', '0', 0, 'Bookmarks bar'),
                    ('2', '0', 1, 'Other bookmarks')
                """)

            try db.create(table: "registeredUserScripts") { t in
                t.column("id", .text).notNull()
                t.column("extensionId", .text).notNull()
                t.column("matches", .text).notNull().defaults(to: "[]")
                t.column("excludeMatches", .text)
                t.column("includeGlobs", .text)
                t.column("excludeGlobs", .text)
                t.column("js", .text).notNull().defaults(to: "[]")
                t.column("allFrames", .boolean).notNull().defaults(to: false)
                t.column("runAt", .text).notNull().defaults(to: "document_idle")
                t.column("world", .text).notNull().defaults(to: "USER_SCRIPT")
                t.column("worldId", .text).notNull().defaults(to: "")
                t.primaryKey(["id", "extensionId"])
            }

            try db.create(table: "userScriptWorldConfigs") { t in
                t.column("extensionId", .text).notNull()
                t.column("worldId", .text).notNull().defaults(to: "")
                t.column("csp", .text)
                t.column("messaging", .boolean).notNull().defaults(to: false)
                t.primaryKey(["extensionId", "worldId"])
            }
            try db.create(index: "idx_registeredUserScripts_extensionId",
                          on: "registeredUserScripts", columns: ["extensionId"])

            try db.create(table: "downloads") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("destinationPath", .text).notNull()
                t.column("bytesReceived", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer).notNull().defaults(to: -1)
                t.column("state", .text).notNull().defaults(to: "inProgress")
                t.column("error", .text)
                t.column("resumeData", .blob)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("mimeType", .text)
                t.column("fileMissing", .boolean).notNull().defaults(to: false)
                t.column("source", .text).notNull().defaults(to: "wk")
            }
            try db.execute(sql: "CREATE INDEX idx_downloads_startedAt ON downloads(startedAt)")

            try db.create(table: "spaceTabStates") { t in
                t.primaryKey("spaceId", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("codec", .text).notNull()
                t.column("state", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // An unreadable spaceTabStates row moves here instead of being overwritten by the next
            // save. Autoincrement key: the same space can be quarantined more than once.
            try db.create(table: "spaceTabStatesQuarantine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("spaceId", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("codec", .text).notNull()
                t.column("state", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("quarantinedAt", .datetime).notNull()
            }

            // Per-tab back/forward list, scroll and form state, restored on a cold launch.
            try db.create(table: "tabInteractionStates") { t in
                t.primaryKey("tabId", .text).notNull()
                t.column("spaceId", .text).notNull()
                t.column("state", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_tabInteractionStates_spaceId", on: "tabInteractionStates", columns: ["spaceId"])

            // Favicons by host, shared by every space in the profile.
            try db.create(table: "favicons") { t in
                t.primaryKey("host", .text).notNull()
                t.column("dataURL", .text).notNull()
                t.column("dominantColor", .text)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.execute(sql: "CREATE INDEX idx_favicons_updatedAt ON favicons(updatedAt)")

            try db.create(table: "extensionSettings") { t in
                t.column("extensionId", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.primaryKey(["extensionId", "key"])
            }
        }

        try migrator.migrate(db)
    }
}
