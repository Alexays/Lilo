import XCTest
@testable import PluginCore
import TestingSupport

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func record(_ url: URL) { lock.withLock { urls.append(url) } }
    var opened: [URL] { lock.withLock { urls } }
}

private final class Grants: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<PluginCapability>
    init(_ set: Set<PluginCapability>) { self.set = set }
    func revoke(_ capability: PluginCapability) { lock.withLock { _ = set.remove(capability) } }
    var current: Set<PluginCapability> { lock.withLock { set } }
}

final class PluginHostAPITests: XCTestCase {
    private var support: URL!
    private let calls = Calls()

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-plugin-api-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
    }

    private func api(_ grants: Grants) -> PluginHostAPI {
        let calls = calls
        return PluginHostAPI(
            pluginID: "app.lilo.test.stub", supportDirectory: support, secrets: InMemoryPluginSecretStore(),
            adapters: PluginHostAdapters(
                listTabs: { [PluginTab(id: "t1", url: "https://example.com/a", title: "A")] },
                openTab: { url in
                    calls.record(url)
                    return PluginTab(id: "t2", url: url.absoluteString, title: "")
                }
            ),
            granted: { grants.current }
        )
    }

    private func params(_ object: [String: JSONValue]) -> JSONValue { .object(object) }

    func testEveryHostMethodMapsToACapability() {
        let methods: [(String, PluginCapability)] = [
            ("settings.get", .settingsStore), ("secrets.set", .settingsStore), ("tabs.list", .tabsRead),
            ("tabs.open", .tabsOpen), ("files.read", .filesPluginDir), ("files.write", .filesPluginDir),
            ("files.list", .filesPluginDir)
        ]
        for (method, capability) in methods { XCTAssertEqual(PluginHostAPI.capability(for: method), capability, method) }
        XCTAssertNil(PluginHostAPI.capability(for: "mystery.call"))
    }

    func testUngrantedCapabilityIsRejectedAndNothingRuns() async {
        let api = api(Grants([.settingsStore]))
        for (method, body) in [
            ("tabs.list", [:]), ("tabs.open", ["url": JSONValue.string("https://example.com")]),
            ("files.write", ["path": .string("a"), "content": .string("x")]), ("files.list", [:])
        ] {
            let result = await api.handle(method, params: params(body))
            XCTAssertEqual(result, .failure(.capabilityNotGranted), method)
        }
        XCTAssertTrue(calls.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testTabsListAndOpenReturnIDURLAndTitle() async throws {
        let api = api(Grants([.tabsRead, .tabsOpen]))
        let listed = try await api.handle("tabs.list", params: .null).get()
        XCTAssertEqual(listed, .object(["tabs": .array([.object([
            "id": .string("t1"), "url": .string("https://example.com/a"), "title": .string("A")
        ])])]))
        let opened = try await api.handle("tabs.open", params: params(["url": .string("https://example.com/b")])).get()
        XCTAssertEqual(opened, .object(["id": .string("t2"), "url": .string("https://example.com/b"), "title": .string("")]))
        XCTAssertEqual(calls.opened, [URL(string: "https://example.com/b")!])
    }

    func testTabsOpenOnlyTakesWebURLs() async {
        let api = api(Grants([.tabsOpen]))
        for url in ["file:///etc/passwd", "javascript:alert(1)", "lilo://settings", "not a url", "https://"] {
            let result = await api.handle("tabs.open", params: params(["url": .string(url)]))
            XCTAssertEqual(result, .failure(.invalidParams("tabs.open needs an http or https url")), url)
        }
        let missing = await api.handle("tabs.open", params: .null)
        XCTAssertEqual(missing, .failure(.invalidParams("tabs.open needs an http or https url")))
        XCTAssertTrue(calls.opened.isEmpty)
    }

    func testFilesStayInTheSupportFolder() async throws {
        let api = api(Grants([.filesPluginDir]))
        _ = try await api.handle("files.write", params: params(["path": .string("state.json"), "content": .string("{}")])).get()
        let read = try await api.handle("files.read", params: params(["path": .string("state.json")])).get()
        XCTAssertEqual(read, .object(["content": .string("{}")]))
        let listed = try await api.handle("files.list", params: .null).get()
        XCTAssertEqual(listed, .object(["entries": .array([.object(["name": .string("state.json"), "isDirectory": .bool(false)])])]))
        let escape = await api.handle("files.read", params: params(["path": .string("../x")]))
        XCTAssertEqual(escape, .failure(.invalidParams("Path must stay inside the plugin's folder")))
        let missing = await api.handle("files.read", params: .null)
        XCTAssertEqual(missing, .failure(.invalidParams("Missing or invalid params for files.read")))
    }

    func testRevokedGrantTakesEffectOnTheNextCallOverTheSession() async throws {
        let grants = Grants([.tabsRead])
        let api = api(grants)
        let transport = StubPluginTransport(onSend: StubPlugin.responder())
        let session = PluginSession(spawn: { transport }, clock: ManualClock())
        await session.set(onRequest: { method, params in await api.handle(method, params: params) }, onExit: {})
        try await session.start()

        func ask(_ id: Int) async throws -> [String: Any] {
            transport.emit(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tabs.list")])
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let reply = transport.sent.compactMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                    .first(where: { $0["id"] as? Int == id }) { return reply }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("no reply for \(id)")
            return [:]
        }

        let granted = try await ask(41)
        XCTAssertEqual(((granted["result"] as? [String: Any])?["tabs"] as? [[String: Any]])?.first?["id"] as? String, "t1")
        grants.revoke(.tabsRead)
        let revoked = try await ask(42)
        XCTAssertEqual((revoked["error"] as? [String: Any])?["code"] as? Int, PluginRequestError.capabilityNotGranted.code)
    }
}
