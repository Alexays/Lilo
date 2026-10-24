import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WKEngineFactoryScriptletTests: XCTestCase {
    /// A key's entries, read back as the scripts do: its record in the sorted index, its list in groups.
    private func entries(of key: String, in table: (index: String, groups: String, entries: String, names: String)) -> [String]? {
        let digits = Array("+/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let index = Array(table.index), groups = Array(table.groups.utf16), entries = Array(table.entries.utf16)
        let hash = Array(WKEngineFactory.keyHash(key))
        guard let record = stride(from: 0, to: index.count, by: 12).first(where: { Array(index[$0..<$0 + 8]) == hash }) else { return nil }
        let group = index[record + 8..<record + 12].reduce(0) { $0 * 64 + digits.firstIndex(of: $1)! }
        let list = String(decoding: groups[group...].prefix { $0 != 0x7C }, as: UTF16.self)
        return list.split(separator: ",").map { offset in
            String(decoding: entries[Int(offset, radix: 36)!...].prefix { $0 != 0xA7 }, as: UTF16.self)
        }
    }

    func testScriptletUserScriptInjectedWhenTableSet() {
        let factory = WKEngineFactory()
        let controller = factory.createTab(configuration: .init()).wkWebView.configuration.userContentController
        XCTAssertFalse(controller.userScripts.contains { $0.source.contains("/*lilo-scriptlets*/") })

        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(cosmetic: nil, sites: nil, scriptlets: "{\"example.com\":[[\"json-prune\",[\"a\"]]]}", procedural: nil))
        let sources = controller.userScripts.map(\.source)
        XCTAssertTrue(sources.contains { $0.contains("/*lilo-scriptlets*/") })
        XCTAssertTrue(sources.contains { $0.contains("\"\(WKEngineFactory.keyHash("example.com"))++++\"") },
                      "the index must be spliced with the host's record")
        XCTAssertTrue(sources.contains { $0.contains("\"0¦a§\"") && $0.contains("var NAMES = \"json-prune\"") },
                      "the entries must be spliced alongside the index, naming their scriptlet by its index")
    }

    /// The installed scripts are the only copy kept: an allowlist edit re-splices them, a paused blocker keeps them for later.
    func testAllowlistAndBlockerToggleRebuildTheScriptsFromTheInstalledOnes() async {
        let factory = WKEngineFactory()
        let controller = factory.createTab(configuration: .init()).wkWebView.configuration.userContentController
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(
            cosmetic: nil, sites: #"{"example.com":[".ad"]}"#, scriptlets: #"{"example.com":[["json-prune",["a"]]]}"#, procedural: nil
        ))
        func allowlists() -> [String] {
            controller.userScripts.compactMap { script in
                guard script.source.contains("/*lilo-") else { return nil }
                return script.source.firstMatch(of: #/var ALLOWLIST = ("[^"]*");/#).map { String($0.1) }
            }
        }
        XCTAssertEqual(allowlists(), [#""||""#, #""||""#])
        await factory.rebuildBlocker(allowlist: BlockerAllowlist(sites: ["a.example", "b.example"]))
        XCTAssertEqual(allowlists(), [#""|a.example|b.example|""#, #""|a.example|b.example|""#])
        factory.applyBlockerChange(enabled: false)
        XCTAssertEqual(allowlists(), [])
        factory.applyBlockerChange(enabled: true)
        await factory.rebuildBlocker(allowlist: BlockerAllowlist())
        XCTAssertEqual(allowlists(), [#""||""#, #""||""#])
        XCTAssertTrue(controller.userScripts.contains { $0.source.contains("\"0¦a§\"") }, "the tables survive every re-splice")
    }

    /// Hashes as the scripts compute them (reference values from an independent FNV-1a).
    func testKeyHashMatchesTheScripts() {
        XCTAssertEqual(WKEngineFactory.keyHash("example.com"), "Elnf7c/M")
        XCTAssertEqual(WKEngineFactory.keyHash("www.youtube.com"), "uaB7hAq4")
    }

    /// Each distinct entry is stored once, each distinct list too, and the index is sorted.
    func testHostTableSharesEntriesAndLists() throws {
        let table = try XCTUnwrap(WKEngineFactory.hostTable(
            for: #"{"a.example":[["n",["x","y"]]],"b.example":[["n",["x","y"]],"sel"],"c.example":["s§"],"d.example":[["n",["x","y"]]]}"#
        ))
        XCTAssertEqual(entries(of: "a.example", in: table), ["0¦x¦y"])
        XCTAssertEqual(entries(of: "b.example", in: table), ["0¦x¦y", "sel"])
        XCTAssertEqual(entries(of: "c.example", in: table), ["sµ00a7"], "a delimiter inside an entry is spelled out")
        XCTAssertNil(entries(of: "e.example", in: table))
        XCTAssertEqual(table.entries.components(separatedBy: "0¦x¦y§").count, 2, "a shared entry is stored once")
        XCTAssertEqual(table.groups.split(separator: "|").count, 3, "a and d share one list")
        let hashes = stride(from: 0, to: table.index.count, by: 12).map { Array(table.index)[$0..<$0 + 8].map(String.init).joined() }
        XCTAssertEqual(hashes, hashes.sorted())
        XCTAssertEqual(table.index.count, 4 * 12)
    }

    /// A scriptlet is named by its index among the names, the most used first; an exception keeps its `@`.
    func testHostTableNamesScriptletsByIndex() throws {
        let table = try XCTUnwrap(WKEngineFactory.hostTable(
            for: #"{"a.example":[["rare",["x"]],["common",[]]],"b.example":[["@common",["y"]],["@",[]]]}"#
        ))
        XCTAssertEqual(table.names, "common rare")
        XCTAssertEqual(entries(of: "a.example", in: table), ["1¦x", "0"])
        XCTAssertEqual(entries(of: "b.example", in: table), ["@0¦y", "@"])
        XCTAssertEqual(try XCTUnwrap(WKEngineFactory.hostTable(for: #"{"a.example":["sel"]}"#)).names, "")
    }

    /// Offsets count UTF-16 code units, as JS string indices do.
    func testHostTableOffsetsCountUTF16() throws {
        let table = try XCTUnwrap(WKEngineFactory.hostTable(for: #"{"a.example":["é😀","z"]}"#))
        XCTAssertEqual(entries(of: "a.example", in: table), ["éµd83dµde00", "z"], "é stays, 😀 is two spelled-out UTF-16 units")
        XCTAssertEqual(table.groups, "0,c|")
    }

    /// The literals must stay escape-free Latin-1, or JSC lexes the whole table on its slow path.
    func testHostTableIsEscapeFreeLatin1() throws {
        let table = try XCTUnwrap(WKEngineFactory.hostTable(for: #"{"a.example":["a\\b\"c\nd\u0001ł"],"bücher.example":["x"]}"#))
        XCTAssertEqual(table.entries, "a¤b¬c¶dµ0001µ0142§")
        XCTAssertEqual(table.index.count, 12, "a host past ASCII never matches punycode location.hostname")
        XCTAssertTrue((table.index + table.groups + table.entries).unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0xFF })
    }

    /// Bucket `FNV-1a(token) % count`, the hash GenericCosmetics.js computes.
    func testTokenBucketsHashAsTheScriptDoes() {
        let buckets = WKEngineFactory.tokenBuckets("ad ad-banner promo bad\"token").split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(buckets.count, 16)
        XCTAssertEqual(buckets[8], "|ad|")
        XCTAssertEqual(buckets[9], "|ad-banner|")
        XCTAssertEqual(buckets[0], "|promo|")
        XCTAssertEqual(WKEngineFactory.tokenBuckets(""), "")
    }

    func testHostTableIsNilWhenTheTableIsUnusable() {
        XCTAssertNil(WKEngineFactory.hostTable(for: "{}"))
        XCTAssertNil(WKEngineFactory.hostTable(for: "{\"a.example\":[]}"))
        XCTAssertNil(WKEngineFactory.hostTable(for: "not json"))
    }

    func testProceduralUserScriptInjectedWhenTableSet() {
        let factory = WKEngineFactory()
        let controller = factory.createTab(configuration: .init()).wkWebView.configuration.userContentController
        XCTAssertFalse(controller.userScripts.contains { $0.source.contains("/*lilo-procedural*/") })

        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(cosmetic: nil, sites: nil, scriptlets: nil, procedural: "{\"example.com\":[\".x:has-text(a)\"]}"))
        let sources = controller.userScripts.map(\.source)
        XCTAssertTrue(sources.contains { $0.contains("/*lilo-procedural*/") })
        XCTAssertTrue(sources.contains { $0.contains("\"\(WKEngineFactory.keyHash("example.com"))++++\"") })
        XCTAssertTrue(sources.contains { $0.contains("\".x:has-text(a)§\"") })
    }

    func testGenericCosmeticsUserScriptIsMainFrameOnly() {
        let factory = WKEngineFactory()
        let scripts = WKEngineFactory.makeFilterScripts(cosmetic: "{\"classes\":\"ad\",\"ids\":\"\",\"links\":{}}", sites: nil, scriptlets: nil, procedural: nil)
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: scripts)
        let script = factory.createTab(configuration: .init()).wkWebView.configuration.userContentController.userScripts
            .first { $0.source.contains("/*lilo-generic-cosmetics*/") }
        XCTAssertEqual(script?.isForMainFrameOnly, true)
    }

    func testSiteCosmeticsAloneInjectTheCosmeticsScript() throws {
        let scripts = WKEngineFactory.makeFilterScripts(cosmetic: nil, sites: #"{"example.com":[".ad"]}"#, scriptlets: nil, procedural: nil)
        let source = try XCTUnwrap(scripts.genericCosmetics)
        XCTAssertTrue(source.contains("\"\(WKEngineFactory.keyHash("example.com"))++++\""))
        XCTAssertTrue(source.contains(#"".ad§""#))
        XCTAssertTrue(source.contains(#"var CLASS_BUCKETS = "";"#), "a missing generic table splices as empty")
    }

    /// Every part keeps the exception tail: an exception only overrides rules of its own list.
    func testRuleListPartsCarryTheExceptionsEach() throws {
        func rule(_ filter: String, _ type: String) -> String { #"{"trigger":{"url-filter":"\#(filter)"},"action":{"type":"\#(type)"}}"# }
        let json = "[" + [rule("a", "block"), rule("b", "block"), rule("c", "block"), rule("x", "ignore-previous-rules")].joined(separator: ",") + "]"
        XCTAssertEqual(WKEngineFactory.ruleListParts(json, limit: 4), [json])
        let parts = try XCTUnwrap(WKEngineFactory.ruleListParts(json, limit: 3))
        let filters = parts.map { part in
            ((try? JSONSerialization.jsonObject(with: Data(part.utf8))) as? [[String: Any]] ?? [])
                .compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        }
        XCTAssertEqual(filters, [["a", "b", "x"], ["c", "x"]])
        XCTAssertNil(WKEngineFactory.ruleListParts(json, limit: 1), "no room left for blocks")
    }

    func testTablesWithoutHostsInjectNothing() {
        let scripts = WKEngineFactory.makeFilterScripts(cosmetic: "", sites: nil, scriptlets: "{}", procedural: "not json")
        XCTAssertEqual(scripts, WKEngineFactory.FilterScripts())
    }
}
