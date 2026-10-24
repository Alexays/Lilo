import XCTest
@testable import Lilo

@MainActor
final class SessionsBridgeHandlerTests: XCTestCase {
    private func message(_ action: String, _ payload: [String: Any] = [:]) throws -> BridgeMessage {
        try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload]))
    }

    func test_getRecentlyClosed_maps_urls_to_sessions_newest_first() async throws {
        let urls = [URL(string: "https://a.example/x")!, URL(string: "https://b.example/y")!]
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosedURLs: urls, restore: { _ in })
        })

        let result = await handler.handle(try message("sessions.getRecentlyClosed"))
        let sessions = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        let firstTab = try XCTUnwrap(sessions.first?["tab"] as? [String: Any])
        XCTAssertEqual(firstTab["url"] as? String, "https://a.example/x")
        XCTAssertEqual(firstTab["sessionId"] as? String, "0")
        XCTAssertEqual(firstTab["title"] as? String, "a.example")
    }

    func test_getRecentlyClosed_honors_maxResults() async throws {
        let urls = (0..<5).map { URL(string: "https://example.com/\($0)")! }
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosedURLs: urls, restore: { _ in })
        })
        let result = await handler.handle(try message("sessions.getRecentlyClosed", ["maxResults": 2]))
        XCTAssertEqual((result as? [[String: Any]])?.count, 2)
    }

    func test_restore_without_sessionId_reopens_the_newest() async throws {
        var restored: [Int] = []
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosedURLs: [URL(string: "https://a.example/x")!], restore: { restored.append($0) })
        })
        _ = await handler.handle(try message("sessions.restore"))
        XCTAssertEqual(restored, [0])
    }

    func test_restore_honors_sessionId() async throws {
        var restored: [Int] = []
        let urls = [URL(string: "https://a.example/x")!, URL(string: "https://b.example/y")!]
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosedURLs: urls, restore: { restored.append($0) })
        })

        let result = await handler.handle(try message("sessions.restore", ["sessionId": "1"]))
        let unknown = await handler.handle(try message("sessions.restore", ["sessionId": "7"]))

        XCTAssertEqual(restored, [1])
        XCTAssertEqual(((result as? [String: Any])?["tab"] as? [String: Any])?["url"] as? String, "https://b.example/y")
        XCTAssertNotNil(unknown as? BridgeError)
    }

    func test_missing_context_returns_error() async throws {
        let handler = SessionsBridgeHandler(contextProvider: { _ in nil })
        let result = await handler.handle(try message("sessions.getRecentlyClosed"))
        XCTAssertNotNil(result as? BridgeError)
    }
}
