import XCTest
@testable import Lilo

@MainActor
final class SessionsBridgeHandlerTests: XCTestCase {
    private func message(_ action: String, _ payload: [String: Any] = [:]) throws -> BridgeMessage {
        try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload]))
    }

    /// A stack holding closed pages of `urls`, the first the newest.
    private func stack(_ urls: [String]) -> RecentlyClosedStack {
        var stack = RecentlyClosedStack()
        for url in urls.reversed() {
            stack.push(.page(URL(string: url)!), spaceId: UUID(), parentFolderId: nil, section: nil, sortOrder: nil)
        }
        return stack
    }

    private func sessionIds(_ result: Any?) -> [String] {
        (result as? [[String: Any]] ?? []).compactMap { ($0["tab"] as? [String: Any])?["sessionId"] as? String }
    }

    func test_getRecentlyClosed_maps_urls_to_sessions_newest_first() async throws {
        let entries = stack(["https://a.example/x", "https://b.example/y"]).recentEntries
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosed: entries, restore: { _ in })
        })

        let result = await handler.handle(try message("sessions.getRecentlyClosed"))
        let sessions = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        let firstTab = try XCTUnwrap(sessions.first?["tab"] as? [String: Any])
        XCTAssertEqual(firstTab["url"] as? String, "https://a.example/x")
        XCTAssertEqual(firstTab["sessionId"] as? String, String(entries[0].id))
        XCTAssertEqual(firstTab["title"] as? String, "a.example")
    }

    func test_getRecentlyClosed_honors_maxResults() async throws {
        let entries = stack((0..<5).map { "https://example.com/\($0)" }).recentEntries
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosed: entries, restore: { _ in })
        })
        let result = await handler.handle(try message("sessions.getRecentlyClosed", ["maxResults": 2]))
        XCTAssertEqual((result as? [[String: Any]])?.count, 2)
    }

    /// A session id names its tab whatever closes or reopens after it, so a restore never reopens another tab.
    func test_sessionIds_survive_later_closes_and_restores() async throws {
        var closed = stack(["https://a.example/", "https://b.example/"])
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosed: closed.recentEntries, restore: { _ in })
        })
        let before = sessionIds(await handler.handle(try message("sessions.getRecentlyClosed")))

        closed.push(.page(URL(string: "https://c.example/")!), spaceId: UUID(), parentFolderId: nil, section: nil, sortOrder: nil)
        let afterClose = sessionIds(await handler.handle(try message("sessions.getRecentlyClosed")))
        _ = closed.pop()
        _ = closed.pop()
        let afterRestore = sessionIds(await handler.handle(try message("sessions.getRecentlyClosed")))

        XCTAssertEqual(Array(afterClose.dropFirst()), before)
        XCTAssertFalse(before.contains(afterClose[0]))
        XCTAssertEqual(afterRestore, [before[1]])
    }

    /// Entries saved by an earlier launch carry no id, and get ids no entry of this launch has.
    func test_restoredEntries_get_their_own_ids() throws {
        var closed = stack(["https://a.example/"])
        let saved = try JSONEncoder().encode([RecentlyClosedStack.Entry(
            content: .terminal(.init(cwd: "/tmp")), spaceId: UUID(), parentFolderId: nil, section: nil, sortOrder: nil
        )])
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("\"id\""))

        closed.restoreOlder(try JSONDecoder().decode([RecentlyClosedStack.Entry].self, from: saved))

        XCTAssertEqual(Set(closed.recentEntries.map(\.id)).count, 2)
    }

    func test_restore_without_sessionId_reopens_the_newest() async throws {
        var restored: [Int] = []
        let entries = stack(["https://a.example/x"]).recentEntries
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosed: entries, restore: { restored.append($0) })
        })
        _ = await handler.handle(try message("sessions.restore"))
        XCTAssertEqual(restored, [0])
    }

    func test_restore_honors_sessionId() async throws {
        var restored: [Int] = []
        let entries = stack(["https://a.example/x", "https://b.example/y"]).recentEntries
        let handler = SessionsBridgeHandler(contextProvider: { _ in
            SessionsContext(recentlyClosed: entries, restore: { restored.append($0) })
        })

        let result = await handler.handle(try message("sessions.restore", ["sessionId": String(entries[1].id)]))
        let unknown = await handler.handle(try message("sessions.restore", ["sessionId": "7777"]))

        XCTAssertEqual(restored, [1])
        XCTAssertEqual(((result as? [String: Any])?["tab"] as? [String: Any])?["url"] as? String, "https://b.example/y")
        XCTAssertNotNil(unknown as? BridgeError)
    }

    func test_missing_context_returns_error() async throws {
        let handler = SessionsBridgeHandler(contextProvider: { _ in nil })
        let result = await handler.handle(try message("sessions.getRecentlyClosed"))
        XCTAssertNotNil(result as? BridgeError)
    }

    /// A page closed or reopened fires `sessions.onChanged` for the extensions of its space's profile only; a terminal never does.
    func test_onChanged_fires_for_the_profile_of_a_closed_page() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileIds = try ["A", "B"].map { try context.profileManager.createProfile(name: $0).id }
        context.profileContexts.pinnedProfileIds = Set(profileIds)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-events-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var listeners: [(registry: ProfileExtensionRegistry, extensionId: String)] = []
        for profileId in profileIds {
            let registry = try context.profileContexts.context(for: profileId).extensions
            let directory = folder.appendingPathComponent(profileId.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["manifest_version": 3, "name": "Sessions", "version": "1.0", "permissions": ["sessions"]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
            try await registry.load(from: directory)
            listeners.append((registry, try XCTUnwrap(registry.loadedExtensions.first?.id)))
        }
        func events(_ index: Int) -> [String] {
            listeners[index].registry.gapEvents.undelivered(to: listeners[index].extensionId)
                .filter { $0.namespace == "sessions" }.map(\.event)
        }
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileIds[0])

        context.recentlyClosed.push(.page(URL(string: "https://example.com")!), spaceId: space.id, parentFolderId: nil, section: nil, sortOrder: nil)
        context.recentlyClosed.push(.terminal(.init(cwd: "/tmp")), spaceId: space.id, parentFolderId: nil, section: nil, sortOrder: nil)
        _ = context.recentlyClosed.pop()
        _ = context.recentlyClosed.pop()

        XCTAssertEqual(events(0), ["onChanged", "onChanged"])
        XCTAssertEqual(events(1), [])
    }
}
