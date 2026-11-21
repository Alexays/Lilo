import XCTest
@testable import Lilo

final class HarnessDefinitionTests: XCTestCase {
    func testEveryDefinitionCanBeDetected() {
        for client in HarnessDefinition.all {
            let detect = client.detect
            XCTAssertTrue(detect.bundleID != nil || detect.binary != nil || !detect.folders.isEmpty, "\(client.id) has nothing to detect it by")
        }
    }

    func testEveryDefinitionIsDocumented() throws {
        for client in HarnessDefinition.all {
            let docs = try XCTUnwrap(URL(string: client.docsURL), client.id)
            XCTAssertEqual(docs.scheme, "https", client.id)
            XCTAssertNotNil(client.verified.wholeMatch(of: /\d{4}-\d{2}-\d{2}/), "\(client.id) verified is a day")
            XCTAssertFalse(client.config.path.isEmpty, client.id)
            XCTAssertFalse(client.handshakes.isEmpty, client.id)
            XCTAssertFalse(client.added().isEmpty, client.id)
        }
    }

    func testIdsAreUniqueAndRoundTrip() {
        let ids = HarnessDefinition.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for client in HarnessDefinition.all { XCTAssertEqual(HarnessDefinition(rawValue: client.id), client) }
        XCTAssertNil(HarnessDefinition(rawValue: "nothing"))
    }

    func testHandshakeNamesMapToTheirClient() {
        XCTAssertEqual(HarnessDefinition(clientName: "Claude-Code"), .claudeCode)
        XCTAssertEqual(HarnessDefinition(clientName: "claude-ai"), .claudeDesktop)
        XCTAssertEqual(HarnessDefinition(clientName: "local-agent-mode-lilo"), .claudeDesktop)
        XCTAssertEqual(HarnessDefinition(clientName: "codex-mcp-client"), .codex)
        XCTAssertEqual(HarnessDefinition(clientName: "cursor-vscode"), .cursor)
        XCTAssertEqual(HarnessDefinition(clientName: "gemini-cli-mcp-client"), .gemini)
        XCTAssertEqual(HarnessDefinition(clientName: "Zed"), .zed)
        XCTAssertNil(HarnessDefinition(clientName: "unknown-agent"))
    }
}
