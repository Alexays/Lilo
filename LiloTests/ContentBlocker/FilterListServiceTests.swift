import os
import XCTest
@testable import Lilo

@MainActor
private final class FilterFactorySpy: FilterRuleApplying {
    var rulesTag: String?
    var externalRules: String?
    var scripts = WKEngineFactory.FilterScripts()
    var rebuildCount = 0

    func setFilterTables(rulesTag: String?, rules: String?, scripts: WKEngineFactory.FilterScripts) {
        self.rulesTag = rulesTag
        externalRules = rules
        self.scripts = scripts
    }
    func rebuildBlocker(allowlist: BlockerAllowlist) async { rebuildCount += 1 }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class FilterListServiceTests: XCTestCase {
    private var factory: FilterFactorySpy!
    private var service: FilterListService!

    override func setUp() {
        factory = FilterFactorySpy()
        service = FilterListService(engineFactory: factory, allowlistProvider: { BlockerAllowlist() })
        // Never touch the real on-disk cache from tests.
        service.persistCache = { _ in }
        service.writeExtension = { _, _ in false }
    }

    override func tearDown() {
        service = nil
        factory = nil
    }

    func testRefreshFailureOfflineSchedulesExactlyOneRetry() async {
        service.fetchList = { _ in nil }
        var retries: [@MainActor () -> Void] = []
        service.retryWhenBackOnline = { retries.append($0); return true }

        await service.refreshIfStale(force: true)
        await service.refreshIfStale(force: true)

        XCTAssertEqual(retries.count, 1, "A second failed refresh must not stack another retry")
        XCTAssertNil(factory.externalRules, "A failed refresh must not touch the applied rules")
        XCTAssertEqual(factory.rebuildCount, 0)
    }

    func testCurrentCacheDoesNotForceRefresh() async {
        let counter = FetchCounter()
        service.fetchList = { _ in
            counter.increment()
            return nil
        }

        await service.applyCachedFilters(rulesTag: "abc", scripts: .init(), isOutdated: false)

        XCTAssertEqual(counter.count, 0, "A current cache must not refetch")
        XCTAssertEqual(factory.rulesTag, "abc")
        XCTAssertNil(factory.externalRules, "A tagged cache leaves the rules on disk")
        XCTAssertEqual(factory.rebuildCount, 1)
    }

    func testOutdatedCacheForcesRefresh() async {
        let counter = FetchCounter()
        service.fetchList = { _ in
            counter.increment()
            return nil
        }

        await service.applyCachedFilters(rulesTag: "abc", scripts: .init(), isOutdated: true)

        XCTAssertGreaterThan(counter.count, 0, "A cache without the cosmetic token table must refetch")
    }

    func testSuccessfulRefreshAppliesAndPersistsTables() async {
        service.fetchList = { _ in "||ads.example.com^\n##.ad-banner\n##a[href*=\"ads\"]" }
        let persistedCache = OSAllocatedUnfairLock<FilterListService.Conversion?>(initialState: nil)
        service.persistCache = { conversion in persistedCache.withLock { $0 = conversion } }

        await service.refreshIfStale(force: true)

        let persisted = persistedCache.withLock { $0 }
        XCTAssertEqual(factory.rebuildCount, 1)
        // JSON escaping doubles the regex backslashes, so match on the stable fragments.
        XCTAssertTrue(factory.externalRules?.contains("ads") == true)
        XCTAssertTrue(factory.externalRules?.contains("\"type\":\"block\"") == true)
        // Bare class/id selectors go to the token table, complex ones to the native rules.
        XCTAssertFalse(factory.externalRules?.contains(".ad-banner") == true)
        XCTAssertTrue(factory.externalRules?.contains("css-display-none") == true)
        XCTAssertTrue(persisted?.cosmetic.contains("ad-banner") == true)
        XCTAssertEqual(persisted?.rules, factory.externalRules)
        XCTAssertEqual(persisted?.rulesTag, factory.rulesTag)
        XCTAssertEqual(persisted?.rulesTag, factory.externalRules.map(WKEngineFactory.stableHash8))
        XCTAssertEqual(persisted?.scripts, factory.scripts, "The applied scripts are the ones cached for the next launch")
        XCTAssertNotNil(persisted?.scripts.genericCosmetics)
    }

    /// The default lists hold about 31,000 generic selectors and 48,000 scriptlet entries: none may fall to a cap.
    func testRefreshKeepsMoreGenericSelectorsAndScriptletsThanTheDefaultListsHold() async {
        let text = ((0...31_000).map { "##.generic-\($0)" } + (0...50_000).map { "s\($0).example##+js(set, x, 1)" }).joined(separator: "\n")
        service.fetchList = { url in url.lastPathComponent == "quick-fixes.txt" ? text : "" }
        await service.refreshNow()
        XCTAssertTrue(factory.scripts.genericCosmetics?.contains("|generic-31000|") == true)
        XCTAssertTrue(factory.scripts.scriptlets?.contains(WKEngineFactory.keyHash("s50000.example")) == true)
    }

    func testOnlyUBlockOriginsOwnListsRunTrustedScriptlets() async {
        service.fetchList = { url in
            url.absoluteString.hasPrefix(FilterListService.trustedListPrefix)
                ? "ubo.example##+js(trusted-set-constant, fromUBO, 1)"
                : "other.example##+js(trusted-set-constant, fromOther, 1)\n!#trusted on\nother.example##+js(rpnt, script, x)\nother.example##+js(set, plain, 1)"
        }
        let persisted = OSAllocatedUnfairLock<FilterListService.Conversion?>(initialState: nil)
        service.persistCache = { conversion in persisted.withLock { $0 = conversion } }

        await service.refreshIfStale(force: true)

        let scriptlets = persisted.withLock { $0 }?.scriptlets ?? ""
        XCTAssertTrue(scriptlets.contains("fromUBO"), scriptlets)
        XCTAssertTrue(scriptlets.contains("plain"), "a list keeps its ordinary scriptlets: \(scriptlets)")
        XCTAssertFalse(scriptlets.contains("fromOther"), scriptlets)
        XCTAssertFalse(scriptlets.contains("replace-node-text"), "a list cannot turn the trust on itself: \(scriptlets)")
    }

    func testRefreshConvertingToTheSameOutputRewritesAndReappliesNothing() async throws {
        let directory = FilterListService.cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "tag".write(to: directory.appendingPathComponent("filter-rules.tag"), atomically: true, encoding: .utf8)
        let persisted = OSAllocatedUnfairLock(initialState: 0)
        service.persistCache = { _ in persisted.withLock { $0 += 1 } }
        var version = 1
        service.fetchList = { [version] _ in "! Version: \(version)\n||ads.example.com^" }

        await service.refreshNow()
        version = 2
        service.fetchList = { [version] _ in "! Version: \(version)\n||ads.example.com^" }
        await service.refreshNow()

        XCTAssertEqual(persisted.withLock { $0 }, 1, "an unchanged conversion leaves the cache as it is")
        XCTAssertEqual(factory.rebuildCount, 1, "an unchanged conversion is not applied again")
    }

    func testLaunchReadsTheCachedScriptsAndResplicesThemOnAKeyMismatch() async throws {
        let directory = FilterListService.cacheURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let cosmetic = #"{"classes":"ad-banner","ids":"","keyed":{},"links":[]}"#
        // A current cache checked just now: the launch neither refetches nor reconverts.
        let files = [
            "filter-rules.json": "[]", "filter-rules.tag": "tag-a", "filter-generic-cosmetics.json": cosmetic,
            "filter-format": FilterListService.cacheStamp(for: FilterListService.sources(for: .init())),
            "filter-rules.meta": String(Date().timeIntervalSince1970)
        ]
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let spliced = WKEngineFactory.makeFilterScripts(cosmetic: cosmetic, sites: nil, scriptlets: nil, procedural: nil)
        XCTAssertNotNil(spliced.genericCosmetics)

        func launch(rulesTag: String) async {
            factory.scripts = .init()
            let service = FilterListService(engineFactory: factory, allowlistProvider: { BlockerAllowlist() })
            service.fetchList = { _ in nil }
            service.retryWhenBackOnline = { _ in false }
            service.start()
            let applied = await pollUntil { self.factory.rulesTag == rulesTag && self.factory.scripts.genericCosmetics != nil }
            XCTAssertTrue(applied, "the launch applies the cached scripts")
        }

        await launch(rulesTag: "tag-a")
        XCTAssertEqual(factory.scripts, spliced, "a first launch splices the tables and caches the scripts")

        let scriptURL = directory.appendingPathComponent("filter-generic-cosmetics.js")
        try "/* cached */".write(to: scriptURL, atomically: true, encoding: .utf8)
        await launch(rulesTag: "tag-a")
        XCTAssertEqual(factory.scripts.genericCosmetics, "/* cached */", "a matching key reads the cached script without splicing")

        try "tag-b".write(to: directory.appendingPathComponent("filter-rules.tag"), atomically: true, encoding: .utf8)
        await launch(rulesTag: "tag-b")
        XCTAssertEqual(factory.scripts, spliced, "another rules tag re-splices the tables")
        XCTAssertEqual(try String(contentsOf: scriptURL, encoding: .utf8), spliced.genericCosmetics)
    }
}
