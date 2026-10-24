import XCTest
import GRDB
@testable import Lilo

@MainActor
final class SitePermissionStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var store: SitePermissionStore!
    private var tempFile: String!

    override func setUp() {
        do {
            let fileName = UUID().uuidString + ".db"
            tempFile = NSTemporaryDirectory() + fileName
            dbPool = try DatabasePool(path: tempFile)
            try dbPool.write { db in
                try db.create(table: "sitePermissions") { t in
                    t.primaryKey("id", .text).notNull()
                    t.column("origin", .text).notNull()
                    t.column("type", .text).notNull()
                    t.column("decision", .text).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
                try db.create(index: "idx_sitePermissions_origin_type", on: "sitePermissions", columns: ["origin", "type"], unique: true)
            }
            store = SitePermissionStore(dbPool: dbPool)
        } catch {
            XCTFail("Failed to set up test database: \(error)")
        }
    }

    override func tearDown() {
        store = nil
        dbPool = nil
        if let tempFile {
            try? FileManager.default.removeItem(atPath: tempFile)
            try? FileManager.default.removeItem(atPath: tempFile + "-shm")
            try? FileManager.default.removeItem(atPath: tempFile + "-wal")
        }
    }

    // MARK: - decision(forOrigin:type:)

    func testDecisionReturnsNilWhenNoRecord() {
        let result = store.decision(forOrigin: "https://example.com", type: "location")
        XCTAssertNil(result)
    }

    // MARK: - Origin and type normalization

    func testDecisionIgnoresCaseAndSurroundingWhitespace() {
        let cases: [(stored: (origin: String, type: String), asked: (origin: String, type: String))] = [
            (("HTTPS://EXAMPLE.COM", "location"), ("https://example.com", "location")),
            (("https://case.example", "Location"), ("https://case.example", "LOCATION")),
            (("  https://space.example  ", "  location  "), ("https://space.example", "location")),
        ]
        for (stored, asked) in cases {
            store.upsert(origin: stored.origin, type: stored.type, granted: true)
            XCTAssertEqual(store.decision(forOrigin: asked.origin, type: asked.type), true, "\(stored) asked as \(asked)")
        }
    }

    // MARK: - upsert

    func testUpsertOverwritesExistingDecision() {
        store.upsert(origin: "https://example.com", type: "location", granted: true)
        store.upsert(origin: "https://example.com", type: "location", granted: false)
        let result = store.decision(forOrigin: "https://example.com", type: "location")
        XCTAssertEqual(result, false)
    }

    func testUpsertCreatesOneRecordNotDuplicates() throws {
        store.upsert(origin: "https://example.com", type: "location", granted: true)
        store.upsert(origin: "https://example.com", type: "location", granted: false)
        let all = store.allPermissions()
        XCTAssertEqual(all.count, 1)
    }

    func testUpsertDifferentTypesAreIndependent() {
        store.upsert(origin: "https://example.com", type: "location", granted: true)
        store.upsert(origin: "https://example.com", type: "camera", granted: false)
        XCTAssertEqual(store.decision(forOrigin: "https://example.com", type: "location"), true)
        XCTAssertEqual(store.decision(forOrigin: "https://example.com", type: "camera"), false)
    }

    func testCombinedCameraAndMicrophoneDecisionUsesSeparateMediaTypes() {
        store.upsert(origin: "https://example.com", type: "camera and microphone", granted: true)

        XCTAssertEqual(store.decision(forOrigin: "https://example.com", type: "camera"), true)
        XCTAssertEqual(store.decision(forOrigin: "https://example.com", type: "microphone"), true)
        XCTAssertEqual(store.decision(forOrigin: "https://example.com", type: "camera and microphone"), true)

        let types = Set(store.allPermissions().map(\.type))
        XCTAssertEqual(types, ["camera", "microphone"])
    }

    func testCombinedCameraAndMicrophoneDecisionDeniesWhenEitherMediaTypeIsDenied() {
        store.upsert(origin: "https://example.com", type: "camera", granted: true)
        store.upsert(origin: "https://example.com", type: "microphone", granted: false)

        XCTAssertEqual(store.decision(forOrigin: "https://example.com", type: "camera and microphone"), false)
    }

    func testUpsertDifferentOriginsAreIndependent() {
        store.upsert(origin: "https://example.com", type: "location", granted: true)
        store.upsert(origin: "https://other.example", type: "location", granted: false)
        XCTAssertEqual(store.decision(forOrigin: "https://example.com", type: "location"), true)
        XCTAssertEqual(store.decision(forOrigin: "https://other.example", type: "location"), false)
    }

    // MARK: - allPermissions

    func testAllPermissionsReturnsEmpty() {
        XCTAssertEqual(store.allPermissions().count, 0)
    }

    func testAllPermissionsReturnsAllRecords() {
        store.upsert(origin: "https://a.example", type: "location", granted: true)
        store.upsert(origin: "https://b.example", type: "camera", granted: false)
        store.upsert(origin: "https://c.example", type: "microphone", granted: true)
        XCTAssertEqual(store.allPermissions().count, 3)
    }

    func testAllPermissionsContainsBridgeData() {
        store.upsert(origin: "https://example.com", type: "location", granted: true)
        let record = try? XCTUnwrap(store.allPermissions().first)
        XCTAssertNotNil(record?.bridgeData["id"] as? String)
        XCTAssertEqual(record?.bridgeData["origin"] as? String, "https://example.com")
        XCTAssertEqual(record?.bridgeData["type"] as? String, "location")
        XCTAssertEqual(record?.bridgeData["decision"] as? String, "allow")
    }

    // MARK: - revoke

    func testRevokeRemovesRecord() {
        store.upsert(origin: "https://example.com", type: "location", granted: true)
        let id = try? XCTUnwrap(store.allPermissions().first?.id)
        if let id { store.revoke(id: id) }
        XCTAssertEqual(store.allPermissions().count, 0)
        XCTAssertNil(store.decision(forOrigin: "https://example.com", type: "location"))
    }

    func testRevokeUnknownIdIsNoop() {
        store.upsert(origin: "https://example.com", type: "location", granted: true)
        store.revoke(id: UUID())
        XCTAssertEqual(store.allPermissions().count, 1)
    }

    func testRevokeOnlyRemovesTargetRecord() {
        store.upsert(origin: "https://a.example", type: "location", granted: true)
        store.upsert(origin: "https://b.example", type: "location", granted: true)
        let id = try? XCTUnwrap(store.allPermissions().first { $0.origin == "https://a.example" }?.id)
        if let id { store.revoke(id: id) }
        XCTAssertEqual(store.allPermissions().count, 1)
        XCTAssertEqual(store.allPermissions().first?.origin, "https://b.example")
    }

    // MARK: - clearAll

    func testClearAllRemovesEverything() {
        store.upsert(origin: "https://a.example", type: "location", granted: true)
        store.upsert(origin: "https://b.example", type: "camera", granted: false)
        store.clearAll()
        XCTAssertEqual(store.allPermissions().count, 0)
    }

    func testClearAllOnEmptyStoreIsNoop() {
        store.clearAll()
        XCTAssertEqual(store.allPermissions().count, 0)
    }

    // MARK: - Geolocation permission bridge

    func testGeolocationBridgeRequestsLocationPermissionForOrigin() {
        let bridge = GeolocationBridge()
        var requestedType: String?
        var requestedOrigin: String?

        bridge.permissionDecisionHandler = { _, type, origin, completion in
            requestedType = type
            requestedOrigin = origin
            completion(false)
        }

        var granted: Bool?
        bridge.requestSitePermission(forOrigin: "https://example.com", webView: nil) { decision in
            granted = decision
        }

        XCTAssertEqual(requestedType, "location")
        XCTAssertEqual(requestedOrigin, "https://example.com")
        XCTAssertEqual(granted, false)
    }

    func testGeolocationBridgeAllowsLocationWhenNoPermissionHandlerIsInstalled() {
        let bridge = GeolocationBridge()

        var granted: Bool?
        bridge.requestSitePermission(forOrigin: "https://example.com", webView: nil) { decision in
            granted = decision
        }

        XCTAssertEqual(granted, true)
    }
}
