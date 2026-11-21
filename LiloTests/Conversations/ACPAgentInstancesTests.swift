import XCTest
@testable import Lilo

final class ACPAgentInstancesTests: XCTestCase {
    func testListReadsWellFormedEntriesAndDropsTheRest() {
        let json = """
        [
          {"id": "claude-acp", "source": "registry", "registryId": "claude-acp", "name": "Claude Agent", "enabled": false},
          {"id": "command-1", "source": "command", "name": "Mine", "executable": "/usr/local/bin/mine",
           "arguments": "--acp", "environment": "MODE=demo"},
          {"source": "command", "executable": "/missing/id"},
          {"id": "unknown", "source": "elsewhere"},
          42
        ]
        """
        let instances = ACPAgentInstance.list(from: json)

        XCTAssertEqual(instances.count, 2)
        XCTAssertEqual(instances[0], ACPAgentInstance(id: "claude-acp", source: .registry, name: "Claude Agent",
                                                      registryId: "claude-acp", enabled: false))
        XCTAssertEqual(instances[1].executable, "/usr/local/bin/mine")
        XCTAssertEqual(instances[1].arguments, "--acp")
        XCTAssertTrue(instances[1].enabled)
        XCTAssertEqual(ACPAgentInstance.list(from: nil), [])
        XCTAssertEqual(ACPAgentInstance.list(from: "not json"), [])
        XCTAssertEqual(ACPAgentInstance.list(from: #"{"a": 1}"#), [])
    }

    func testListRoundTripsThroughItsJSON() {
        let instances = [
            ACPAgentInstance(id: "command-1", source: .command, name: "Mine", executable: "/opt/mine",
                             arguments: "--profile\nacp", environment: "A=b", enabled: false),
            ACPAgentInstance(id: "gemini", source: .registry, name: "Gemini CLI", registryId: "gemini")
        ]

        XCTAssertEqual(ACPAgentInstance.list(from: ACPAgentInstance.json(instances)), instances)
    }

    /// The old setting's executable becomes a command entry that keeps the "custom" id, so a
    /// conversation started with it still finds its agent.
    func testTheCustomAgentMigratesToTheFirstCommandEntry() throws {
        let instance = try XCTUnwrap(ACPAgentInstance.migrate(customAgent: #"{"name": "Mine", "executable": " /opt/mine ", "arguments": "--acp", "environment": "A=1"}"#))

        XCTAssertEqual(instance.id, "custom")
        XCTAssertEqual(instance.source, .command)
        XCTAssertEqual(instance.name, "Mine")
        XCTAssertEqual(instance.executable, "/opt/mine")
        XCTAssertTrue(instance.enabled)

        for json: String? in [nil, "not json", "{}", #"{"executable": "  "}"#] {
            XCTAssertNil(ACPAgentInstance.migrate(customAgent: json))
        }
    }

    @MainActor
    func testCatalogResolvesCommandInstancesByTheirId() async throws {
        let catalog = ACPAgentCatalog(directory: FileManager.default.temporaryDirectory)
        catalog.instancesSetting = {
            ACPAgentInstance.json([
                ACPAgentInstance(id: "command-1", source: .command, name: "Mine", executable: "/opt/mine", arguments: "--acp", enabled: false),
                ACPAgentInstance(id: "gemini", source: .registry, name: "Gemini CLI", registryId: "gemini"),
                ACPAgentInstance(id: "command-2", source: .command, executable: "  ")
            ])
        }

        // A disabled command still resolves: a conversation running it keeps working.
        let agent = try XCTUnwrap(catalog.agent(id: "command-1"))
        XCTAssertEqual(agent.name, "Mine")
        guard case .command(let executable, let args, _) = agent.distribution else { return XCTFail("a command agent") }
        XCTAssertEqual(executable, "/opt/mine")
        XCTAssertEqual(args, ["--acp"])
        XCTAssertNil(catalog.agent(id: "command-2"), "an empty executable is no agent")
        // Registry entries are the catalog's own, whether listed or not.
        XCTAssertEqual(catalog.agent(id: "gemini")?.name, "Gemini CLI")

        let runnable = await catalog.runnableAgents()
        XCTAssertTrue(runnable.contains { $0.id == "command-1" && $0.isCommand })
        XCTAssertFalse(runnable.contains { $0.id == "command-2" })
    }
}
