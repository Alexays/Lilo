import XCTest
import GRDB
@testable import Lilo

@MainActor
final class SchemaExtensionsTests: XCTestCase {

    private var database: TemporaryProfileDatabase!
    private var dbPool: DatabasePool { database.pool }

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase(schema: .global)
    }

    override func tearDownWithError() throws {
        database.tearDown()
        database = nil
    }

    private func installedExtensionsColumns(in db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(installed_extensions)")
    }

    private func installedExtensionsForeignKeys(in db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(installed_extensions)")
    }

    private func installedExtensionsIndexColumns(named indexName: String, in db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA index_info(\(indexName))").map { $0["name"] }
    }

    // MARK: - Schema Verification Tests

    func testColumnsExist() throws {
        try dbPool.read { db in
            let columnNames = try installedExtensionsColumns(in: db).map { $0["name"] as String }
            let requiredColumns = ["id", "profile_id", "name", "version", "enabled", "install_type", "install_date", "path"]

            for column in requiredColumns {
                XCTAssertTrue(columnNames.contains(column), "Column '\(column)' must exist")
            }
        }
    }

    func testInstalledExtensionsAreKeyedByIdAndProfile() throws {
        try dbPool.read { db in
            let primaryKeyColumns = try installedExtensionsColumns(in: db)
                .filter { ($0["pk"] as Int64) > 0 }
                .sorted { ($0["pk"] as Int64) < ($1["pk"] as Int64) }
                .map { $0["name"] as String }
            XCTAssertEqual(Set(primaryKeyColumns), Set(["id", "profile_id"]), "Primary key must be (id, profile_id)")
        }
    }

    func testInstalledExtensionsGoWithTheirProfile() throws {
        try dbPool.read { db in
            let profileForeignKey = try installedExtensionsForeignKeys(in: db).first { row in
                (row["from"] as String) == "profile_id"
            }

            XCTAssertNotNil(profileForeignKey, "Foreign key on profile_id must exist")
            XCTAssertEqual(profileForeignKey?["table"] as String?, "profiles", "Foreign key must reference profiles table")
            XCTAssertEqual(profileForeignKey?["from"] as String?, "profile_id", "Foreign key column must be profile_id")
            XCTAssertEqual(profileForeignKey?["to"] as String?, "id", "Foreign key must reference profiles.id")
            XCTAssertEqual(profileForeignKey?["on_delete"] as String?, "CASCADE", "Foreign key must cascade on delete")
        }
    }

    func testIndexOnProfileId() throws {
        try dbPool.read { db in
            let index = try Row.fetchAll(db, sql: "PRAGMA index_list(installed_extensions)").first { row in
                (row["name"] as String) == "idx_installed_extensions_profile_id"
            }

            XCTAssertNotNil(index, "Index on profile_id must exist")
            let indexColumns = try installedExtensionsIndexColumns(named: "idx_installed_extensions_profile_id", in: db)
            XCTAssertEqual(indexColumns, ["profile_id"], "Index must be on profile_id column")
        }
    }

    func testCascadeDelete() throws {
        let profileId = UUID().uuidString
        let extensionId = "test-extension-1"

        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO profiles (id, name, isDefault, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [profileId, "Test Profile", false, Date(), Date()]
            )

            try db.execute(
                sql: "INSERT INTO installed_extensions (id, profile_id, name, version, enabled, install_type, install_date, path) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [extensionId, profileId, "Test Extension", "1.0.0", 1, "normal", Date(), "/path/to/extension"]
            )

            let countBefore = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM installed_extensions WHERE profile_id = ?",
                arguments: [profileId]
            )
            XCTAssertEqual(countBefore, 1)

            try db.execute(sql: "DELETE FROM profiles WHERE id = ?", arguments: [profileId])

            let countAfter = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM installed_extensions WHERE profile_id = ?",
                arguments: [profileId]
            )
            XCTAssertEqual(countAfter, 0, "Extension should be cascade deleted when profile is deleted")
        }
    }

    func testDefaultValues() throws {
        let profileId = UUID().uuidString
        let extensionId = "test-extension"

        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO profiles (id, name, isDefault, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [profileId, "Test Profile", false, Date(), Date()]
            )

            try db.execute(
                sql: "INSERT INTO installed_extensions (id, profile_id, name, version, path) VALUES (?, ?, ?, ?, ?)",
                arguments: [extensionId, profileId, "Test Extension", "1.0.0", "/path/to/extension"]
            )

            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM installed_extensions WHERE id = ?",
                arguments: [extensionId]
            )
            XCTAssertEqual(row?["enabled"] as? Int64, 1, "enabled should default to 1")
            XCTAssertEqual(row?["install_type"] as? String, "normal", "install_type should default to 'normal'")
            XCTAssertNotNil(row?["install_date"], "install_date should have a default value")
        }
    }

    func testTabFoldersTableIsDroppedFromGlobalSchema() throws {
        try dbPool.read { db in
            XCTAssertFalse(try db.tableExists("tabFolders"))
        }
    }

    func testDatabaseManagerDoesNotRecoverOrphanedProfileSpacesDuringStartup() throws {
        let appSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileId = UUID()
        let spaceId = UUID()
        let activeTabId = UUID()
        let profileDirectory = appSupportURL
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileId.uuidString, isDirectory: true)
        let profileDBURL = profileDirectory.appendingPathComponent("lilo.db")
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let profilePool = try DatabasePool(path: profileDBURL.path)
        defer {
            try? profilePool.close()
            try? FileManager.default.removeItem(at: appSupportURL)
        }
        try Migrations.migrateProfile(profilePool)

        let state = SpaceTabState(
            activeTabId: activeTabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [
                    .tab(StoredTab(
                        id: activeTabId,
                        url: "https://state.example",
                        title: "Recovered State",
                        faviconDataURL: nil,
                        faviconDominantColor: nil,
                        isPinned: true,
                        isBookmarked: false,
                        isClosed: false,
                        homeURL: nil,
                        homeTitle: nil,
                        homeFaviconDataURL: nil,
                        homeFaviconDominantColor: nil
                    ))
                ],
                unpinned: [],
                bookmarked: []
            )
        )
        try SpaceTabStateStore(dbPool: profilePool).saveMany([(spaceId: spaceId, state: state)])

        let dbManager = try DatabaseManager(appSupportDirectory: appSupportURL.path)
        defer {
            dbManager.closeForShutdown()
        }

        try dbManager.globalPool.read { db in
            let profiles = try Profile.fetchAll(db)
            let spaces = try Space.fetchAll(db)
            XCTAssertTrue(profiles.isEmpty)
            XCTAssertTrue(spaces.isEmpty)
        }
    }

    /// Space/Profile UUID columns must persist as uppercase TEXT: the managers filter on
    /// `== id.uuidString`, and a blob-encoded UUID would silently match nothing.
    func testSpaceAndProfileUUIDColumnsRoundTripAsUppercaseText() throws {
        let profile = Profile(name: "Test")
        let space = Space(profileId: profile.id, activeTabId: UUID())
        try dbPool.write { db in
            try profile.insert(db)
            try space.insert(db)
        }

        let fetchedSpace = try dbPool.read { db in
            try Space.filter(Space.Columns.profileId == profile.id.uuidString).fetchOne(db)
        }
        XCTAssertEqual(fetchedSpace?.id, space.id)
        XCTAssertEqual(fetchedSpace?.activeTabId, space.activeTabId)

        let fetchedProfile = try dbPool.read { db in
            try Profile.filter(Column("id") == profile.id.uuidString).fetchOne(db)
        }
        XCTAssertEqual(fetchedProfile?.id, profile.id)

        let storedSpaceId = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM spaces WHERE profileId = ?", arguments: [profile.id.uuidString])
        }
        XCTAssertEqual(storedSpaceId, space.id.uuidString)
    }

}
