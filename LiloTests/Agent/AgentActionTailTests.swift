import XCTest
@testable import Lilo

final class AgentActionTailTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory.appending(path: "action-tail-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ tool: String, host: String? = "example.com", ok: Bool = true, code: String? = nil, ts: String = "2026-01-02T03:04:05.000Z") -> String {
        var entry: [String: Any] = ["ts": ts, "tool": tool, "ok": ok, "args": ["url": "example.com"], "duration_ms": 3]
        if let host { entry["host"] = host }
        if let code { entry["code"] = code }
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])) ?? Data()
        return (String(bytes: data, encoding: .utf8) ?? "") + "\n"
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appending(path: name + ".jsonl"), atomically: true, encoding: .utf8)
    }

    func testTheLastCallsComeNewestFirst() throws {
        try write("client-a", (1...12).map { line("tool\($0)") }.joined())
        XCTAssertEqual(AgentActionTail.recent("client-a", in: directory, limit: 3).map(\.tool), ["tool12", "tool11", "tool10"])
    }

    func testAMissingFileIsEmpty() {
        XCTAssertEqual(AgentActionTail.recent("client-none", in: directory, limit: 5), [])
        XCTAssertEqual(AgentActionTail.clients(in: directory.appending(path: "absent"), names: [:]), [])
    }

    func testATruncatedLastLineIsDropped() throws {
        let partial = String(line("cut").dropLast(12))
        try write("client-a", line("one") + line("two") + partial)
        XCTAssertEqual(AgentActionTail.recent("client-a", in: directory, limit: 5).map(\.tool), ["two", "one"])
    }

    func testJunkLinesAreSkippedAndFieldsKept() throws {
        try write("client-a", "not json\n{\"tool\":1}\n" + line("click", host: nil, ok: false, code: "denied"))
        let calls = AgentActionTail.recent("client-a", in: directory, limit: 5)
        XCTAssertEqual(calls, [AgentActionTail.Call(time: "2026-01-02T03:04:05.000Z", tool: "click", host: nil, ok: false, code: "denied")])
    }

    func testAHugeFileIsReadOnlyFromItsEnd() throws {
        let filler = String(repeating: line("old"), count: 20_000)
        try write("client-a", filler + line("recent1") + line("recent2"))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appending(path: "client-a.jsonl").path)[.size] as? Int)
        XCTAssertGreaterThan(size, 1 << 20)
        XCTAssertEqual(AgentActionTail.recent("client-a", in: directory, limit: 2, maxBytes: 4096).map(\.tool), ["recent2", "recent1"])
        XCTAssertEqual(AgentActionTail.recent("client-a", in: directory, limit: 10_000, maxBytes: 4096).count < 100, true, "never more than the byte cap")
    }

    func testAShortLiveFileContinuesInTheRotatedOne() throws {
        try write("client-a.1", line("older1") + line("older2"))
        try write("client-a", line("fresh"))
        XCTAssertEqual(AgentActionTail.recent("client-a", in: directory, limit: 3).map(\.tool), ["fresh", "older2", "older1"])
    }

    func testClientsListNamesAndSkipConversationsAndRotatedFiles() throws {
        try write("client-claude-code", line("a"))
        try write("client-claude-code.1", line("b"))
        try write("client-stranger", line("c"))
        try write("conversation-\(UUID().uuidString)", line("d"))
        try write("client-empty", "")
        let clients = AgentActionTail.clients(in: directory, names: [AgentActionLog.clientFile("claude-code"): "Claude Code"])
        XCTAssertEqual(Set(clients.map(\.name)), ["Claude Code", "stranger"])
    }
}
