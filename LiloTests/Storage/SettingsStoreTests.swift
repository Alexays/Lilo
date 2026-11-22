import GRDB
import XCTest
@testable import Lilo

@MainActor
final class SettingsStoreTests: XCTestCase {

    private var database: TemporaryProfileDatabase!
    private var dbPool: DatabasePool { database.pool }

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase(schema: .global)
    }

    override func tearDown() {
        database.tearDown()
        database = nil
    }

    /// Reads are served from the in-memory mirror; the queued write must still land in SQLite so
    /// a fresh store on the same pool sees the value.
    func testSetRoundTripsThroughDatabase() throws {
        let store = SettingsStore(dbPool: dbPool)
        store.set("theme", value: "dark")
        XCTAssertEqual(store.get("theme"), "dark")

        try dbPool.write { _ in } // waits for the queued write
        let reloaded = SettingsStore(dbPool: dbPool)
        XCTAssertEqual(reloaded.get("theme"), "dark")
        XCTAssertEqual(reloaded.allSettings(), SettingsStore.defaults.merging(["theme": "dark"]) { $1 })
    }

    func testADefaultIsServedUntilChangedAndComesBackWhenCleared() throws {
        let store = SettingsStore(dbPool: dbPool)
        XCTAssertEqual(store.get("agentSystemPrompt"), "lilo")

        store.set("agentSystemPrompt", value: "agent")
        store.set("agentSystemPromptText", value: "Be brief.")
        XCTAssertEqual(store.allSettings()["agentSystemPrompt"], "agent")
        XCTAssertEqual(store.get("agentSystemPromptText"), "Be brief.")

        store.set("agentSystemPromptText", value: "")
        try dbPool.write { _ in }
        let reloaded = SettingsStore(dbPool: dbPool)
        XCTAssertEqual(reloaded.get("agentSystemPromptText"), ConversationHost.liloSystemPrompt)
        XCTAssertEqual(reloaded.get("agentSystemPrompt"), "agent")
    }

    func testGlobalPrivacyControlIsOnUntilTurnedOff() {
        let store = SettingsStore(dbPool: dbPool)
        XCTAssertTrue(store.sendGPC)

        store.set("sendGPC", value: "false")
        XCTAssertFalse(store.sendGPC)
    }

    func testRemoveDeletesFromMemoryAndDatabase() throws {
        let store = SettingsStore(dbPool: dbPool)
        store.set("searchEngine", value: "brave")
        store.remove("searchEngine")
        XCTAssertNil(store.get("searchEngine"))

        try dbPool.write { _ in } // waits for the queued writes
        let reloaded = SettingsStore(dbPool: dbPool)
        XCTAssertNil(reloaded.get("searchEngine"))
    }
}
