import WebKit
import XCTest
@testable import Lilo

/// `BridgeRouter.isTrustedChromeMessage` is the caller-authentication guard that gates privileged
/// bridge handlers. `WKScriptMessage`/`WKFrameInfo` are not constructible in a unit test, so the
/// guard's decision lives in this pure function and is tested directly.
@MainActor
final class BridgeRouterTests: XCTestCase {

    // MARK: - Trusted: main frame, lilo-chrome:// scheme

    func testTrustsChromeSchemeMainFrame() {
        XCTAssertTrue(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "lilo-chrome"))
        XCTAssertTrue(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "LILO-CHROME"))
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: false, originScheme: "lilo-chrome"))
    }

    func testRejectsOpaqueOriginMainFrame() {
        // The chrome UI is never delivered via loadHTMLString(baseURL: nil); an empty scheme
        // means an unexpected opaque-origin document and must not reach privileged handlers.
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: ""))
    }

    // MARK: - Rejected: any sub-frame, regardless of origin

    func test_subFrame_opaqueOrigin_isRejected() {
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: false, originScheme: ""))
    }

    func test_subFrame_httpsOrigin_isRejected() {
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: false, originScheme: "https"))
    }

    func test_subFrame_extensionOrigin_isRejected() {
        // A chrome-extension iframe embedded in the chrome web view must not reach these handlers.
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: false, originScheme: "chrome-extension"))
    }

    // MARK: - Main-frame navigation to hostile content

    func test_mainFrame_hostileHttpOrigin_isRejectedInRelease() {
        // A main-frame navigation away from the trusted chrome content (e.g. to http/https) must be
        // rejected in release builds; only the DEBUG dev-server path accepts http/https.
        #if DEBUG
        XCTAssertTrue(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "https"))
        XCTAssertTrue(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "http"))
        #else
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "https"))
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "http"))
        #endif
    }

    func test_mainFrame_customScheme_isRejected() {
        // A non-empty, non-http(s) scheme on the main frame is never the trusted chrome context.
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "chrome-extension"))
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "file"))
    }

    // MARK: - Case-insensitivity

    func test_originScheme_isCaseInsensitive() {
        #if DEBUG
        XCTAssertTrue(BridgeRouter.isTrustedChromeMessage(isMainFrame: true, originScheme: "HTTPS"))
        #endif
        XCTAssertFalse(BridgeRouter.isTrustedChromeMessage(isMainFrame: false, originScheme: "HTTP"))
    }
}

/// Wire-order tests for the coalescer/sequencer/silencing interplay, observed through the
/// `javaScriptSink` seam (each sink call is one Swift-to-JS hop, in dispatch order).
@MainActor
final class BridgeRouterWireOrderTests: XCTestCase {

    private enum Wire {
        case single([String: Any])
        case batch([[String: Any]])
    }

    private var router: BridgeRouter!
    private var wires: [Wire] = []
    /// When set, calls stay in flight until the test runs their completion from `heldCompletions`.
    private var holdsCalls = false
    private var heldCompletions: [@MainActor () -> Void] = []

    override func setUp() {
        super.setUp()
        router = BridgeRouter(chromeWebView: WKWebView())
        wires = []
        holdsCalls = false
        heldCompletions = []
        router.javaScriptSink = { [weak self] _, arguments, completion in
            guard let self else { return }
            if let batch = arguments["messages"] as? [[String: Any]] {
                self.wires.append(.batch(batch))
            } else if let message = arguments["message"] as? [String: Any] {
                self.wires.append(.single(message))
            }
            if self.holdsCalls { self.heldCompletions.append(completion) } else { completion() }
        }
    }

    override func tearDown() {
        router = nil
        super.tearDown()
    }

    private func pumpRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func singleMessage(_ wire: Wire) -> [String: Any]? {
        if case .single(let message) = wire { return message }
        return nil
    }

    func test_bufferedPatchThenRawSend_arrivesFlushFirstWithContiguousSeq() {
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "A"])
        XCTAssertTrue(wires.isEmpty, "a coalescable patch must sit in the flush window, not ship immediately")

        router.send(event: "browserStateChanged", data: [:])
        XCTAssertTrue(wires.isEmpty, "a raw send waits for the end of the main-loop turn")

        drainMainQueue()
        XCTAssertEqual(wires.count, 1, "the buffered patch and the raw send ship in one call")
        guard case .batch(let batch)? = wires.first else {
            return XCTFail("expected a receiveBatch dispatch, got \(wires)")
        }
        XCTAssertEqual(batch.map { $0["event"] as? String }, ["browserStatePatch", "browserStateChanged"])
        XCTAssertEqual(batch.map { $0["stateSeq"] as? Int }, [1, 2])

        pumpRunLoop(seconds: 0.06)
        XCTAssertEqual(wires.count, 1, "the 16 ms flush finds nothing left to ship")
    }

    func test_rawSendsOfOneTurn_shipInOrderInOneCall_withCoalescedEventsSentBetween() {
        router.send(event: "browserStateChanged", data: ["n": 1])
        router.send(event: "trackersBlockedChanged", data: ["count": 3])
        router.send(event: "browserStateChanged", data: ["n": 2])
        router.send(event: "commandKeyChanged", data: ["down": true])
        XCTAssertTrue(wires.isEmpty)

        drainMainQueue()
        XCTAssertEqual(wires.count, 1)
        guard case .batch(let batch)? = wires.first else {
            return XCTFail("expected a receiveBatch dispatch, got \(wires)")
        }
        XCTAssertEqual(
            batch.map { $0["event"] as? String },
            ["browserStateChanged", "trackersBlockedChanged", "browserStateChanged", "commandKeyChanged"]
        )
        XCTAssertEqual(batch.map { $0["stateSeq"] as? Int }, [1, nil, 2, nil])
    }

    func test_rawSendWhileSilenced_shipsAtTurnEnd_andLaterCoalescedEventsStayHeld() {
        router.isSilenced = true
        router.send(event: "browserStateChanged", data: [:])
        router.send(event: "trackersBlockedChanged", data: ["count": 3])

        drainMainQueue()
        pumpRunLoop(seconds: 0.06)
        XCTAssertEqual(wires.count, 1)
        XCTAssertEqual(singleMessage(wires[0])?["event"] as? String, "browserStateChanged")

        router.isSilenced = false
        XCTAssertEqual(wires.count, 2)
        XCTAssertEqual(singleMessage(wires[1])?["event"] as? String, "trackersBlockedChanged")
    }

    func test_unsilencingFlushesExactlyOnce_withContiguousSeqAcrossBatch() {
        router.isSilenced = true
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "A"])
        router.send(event: "browserStatePatch", data: ["tabId": "t2", "title": "B"])
        XCTAssertTrue(wires.isEmpty, "silenced patches must accumulate, not ship")

        router.isSilenced = false
        XCTAssertEqual(wires.count, 1, "unsilencing must flush the accumulated patches in one batch")
        guard case .batch(let batch)? = wires.first else {
            return XCTFail("expected a receiveBatch dispatch, got \(wires)")
        }
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(Set(batch.compactMap { $0["stateSeq"] as? Int }), [1, 2])

        router.send(event: "browserStateChanged", data: [:])
        drainMainQueue()
        XCTAssertEqual(wires.count, 2)
        XCTAssertEqual(singleMessage(wires[1])?["stateSeq"] as? Int, 3, "seq must stay contiguous across receiveBatch")

        pumpRunLoop(seconds: 0.06)
        XCTAssertEqual(wires.count, 2, "no stale scheduled flush may fire again after the unsilence flush")
    }

    func test_flushScheduledBeforeSilencing_doesNotShipToOccludedWindow() {
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "A"])
        router.isSilenced = true

        pumpRunLoop(seconds: 0.06)
        XCTAssertTrue(wires.isEmpty, "a flush scheduled before silencing must not fire while silenced")

        router.isSilenced = false
        XCTAssertEqual(wires.count, 1, "the held patch ships exactly once on unsilence")
        XCTAssertEqual(singleMessage(wires[0])?["event"] as? String, "browserStatePatch")

        pumpRunLoop(seconds: 0.06)
        XCTAssertEqual(wires.count, 1)
    }

    func test_sendsDuringCallInFlight_shipAfterItInOneOrderedBatch() {
        holdsCalls = true
        router.send(event: "browserStateChanged", data: ["n": 1])
        drainMainQueue()
        XCTAssertEqual(wires.count, 1)

        router.send(event: "browserStateChanged", data: ["n": 2])
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "A"])
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "B"])
        router.send(event: "browserStateChanged", data: ["n": 3])
        pumpRunLoop(seconds: 0.06)
        XCTAssertEqual(wires.count, 1, "nothing ships while a call is in flight")

        heldCompletions.removeFirst()()
        XCTAssertEqual(wires.count, 2, "what waited ships as soon as the call completes")
        guard case .batch(let batch) = wires[1] else {
            return XCTFail("expected a receiveBatch dispatch, got \(wires[1])")
        }
        XCTAssertEqual(batch.map { $0["event"] as? String }, ["browserStateChanged", "browserStatePatch", "browserStateChanged"])
        XCTAssertEqual(batch.map { $0["n"] as? Int }, [2, nil, 3])
        XCTAssertEqual(batch[1]["title"] as? String, "B", "patches keep merging while they wait")
        XCTAssertEqual(batch.map { $0["stateSeq"] as? Int }, [2, 3, 4])
        XCTAssertEqual(heldCompletions.count, 1, "the batch is the one call in flight")

        heldCompletions.removeFirst()()
        pumpRunLoop(seconds: 0.06)
        XCTAssertEqual(wires.count, 2)
    }

    func test_sidebarPatchesWaitingTogether_shipOnlyEachSpacesNewestTree() {
        func patch(_ space: String, _ tab: String) -> [String: Any] {
            ["changedSpaceId": space, "operations": [["kind": "sidebarChanged", "spaceId": space, "upsertTabs": [["id": tab]],
                                                      "treeItems": [["itemId": tab]]]]]
        }
        holdsCalls = true
        router.send(event: "browserStateChanged", data: [:])
        drainMainQueue()
        router.send(event: "browserStatePatch", data: patch("s1", "a"))
        router.send(event: "browserStatePatch", data: patch("s2", "x"))
        router.send(event: "browserStatePatch", data: patch("s1", "b"))
        heldCompletions.removeFirst()()

        guard case .batch(let batch) = wires[1] else { return XCTFail("expected a receiveBatch dispatch, got \(wires[1])") }
        let operations = batch.compactMap { ($0["operations"] as? [[String: Any]])?.first }
        XCTAssertEqual(operations.map { ($0["upsertTabs"] as? [[String: Any]])?.first?["id"] as? String }, ["a", "x", "b"], "every upsert ships")
        XCTAssertEqual(operations.map { $0["treeItems"] != nil }, [false, true, true], "s1's first tree is superseded by its second")
    }

    func test_aNewerWholeTreeSupersedesOlderTreeDeltasButADeltaSupersedesNothing() {
        func patch(_ tab: String, _ tree: String) -> [String: Any] {
            ["changedSpaceId": "s1", "operations": [["kind": "sidebarChanged", "spaceId": "s1", tree: [["itemId": tab]]]]]
        }
        holdsCalls = true
        router.send(event: "browserStateChanged", data: [:])
        drainMainQueue()
        router.send(event: "browserStatePatch", data: patch("a", "treeItems"))
        router.send(event: "browserStatePatch", data: patch("b", "upsertTreeItems"))
        router.send(event: "browserStatePatch", data: patch("c", "treeItems"))
        router.send(event: "browserStatePatch", data: patch("d", "upsertTreeItems"))
        heldCompletions.removeFirst()()

        guard case .batch(let batch) = wires[1] else { return XCTFail("expected a receiveBatch dispatch, got \(wires[1])") }
        let operations = batch.compactMap { ($0["operations"] as? [[String: Any]])?.first }
        XCTAssertEqual(operations.map { $0["treeItems"] != nil }, [false, false, true, false])
        XCTAssertEqual(operations.map { $0["upsertTreeItems"] != nil }, [false, false, false, true])
    }

    func test_coalescedEventsDuringCallInFlight_keepMergingAndShipInTheirWindowAfterIt() {
        holdsCalls = true
        router.send(event: "browserStateChanged", data: [:])
        drainMainQueue()
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "A"])
        pumpRunLoop(seconds: 0.06)
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "B"])
        XCTAssertEqual(wires.count, 1)

        heldCompletions.removeFirst()()
        XCTAssertEqual(wires.count, 1, "coalesced events alone wait for their 16 ms window")

        let deadline = Date().addingTimeInterval(5)
        while wires.count < 2, Date() < deadline { pumpRunLoop(seconds: 0.01) }
        XCTAssertEqual(wires.count, 2)
        let patch = singleMessage(wires[1])
        XCTAssertEqual(patch?["title"] as? String, "B")
        XCTAssertEqual(patch?["stateSeq"] as? Int, 2)
    }

    func test_silencedCoalescedEventsStayHeldAfterCallInFlight() {
        holdsCalls = true
        router.send(event: "browserStateChanged", data: [:])
        drainMainQueue()
        router.isSilenced = true
        router.send(event: "browserStatePatch", data: ["tabId": "t1", "title": "A"])

        heldCompletions.removeFirst()()
        pumpRunLoop(seconds: 0.06)
        XCTAssertEqual(wires.count, 1, "an occluded window keeps holding its coalesced events")

        router.isSilenced = false
        XCTAssertEqual(wires.count, 2)
        XCTAssertEqual(singleMessage(wires[1])?["stateSeq"] as? Int, 2)
    }
}

/// Commands are hand-typed on the TypeScript side: every action the chrome bridge handles must
/// appear in `BridgeCommandPayloadMap`, or the UI can only send it through an untyped call.
@MainActor
final class BridgeCommandMapCoverageTests: XCTestCase {
    func testEveryChromeBridgeActionIsInTheTypeScriptCommandMap() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let window = MainWindowController(context: browserContext.context)
        window.setupBridgeEarly()
        window.setupBridgeLate()

        let protocolURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lilo-ui/src/lib/bridge/protocol.ts")
        let source = try String(contentsOf: protocolURL, encoding: .utf8)
        let mapBody = try XCTUnwrap(source.components(separatedBy: "export interface BridgeCommandPayloadMap {").last?
            .components(separatedBy: "\n}").first)
        // Top-level members sit one tab deep: `\tname: ...` or `\t"dotted.name": ...`.
        let commandNames = Set(mapBody.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t"), let colon = line.firstIndex(of: ":") else { return nil }
            return line[line.startIndex..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "\t\"?"))
        })

        let missing = Set(window.bridgeRouter.handlers.keys).subtracting(commandNames)
        XCTAssertTrue(missing.isEmpty, "handled actions missing from BridgeCommandPayloadMap: \(missing.sorted())")
    }
}

/// Events reach a real page intact and in order, whether they cross as JSON or, when JSON cannot carry them, as objects.
@MainActor
final class BridgeRouterPageDeliveryTests: XCTestCase {
    func testEventsArriveIntactInOrderAsJSONOrObjects() async throws {
        let web = WKWebView()
        web.loadHTMLString("<script>window.got = []; window.__lilo = { receive: (m) => got.push(m), receiveBatch: (ms) => got.push(...ms) };</script>",
                           baseURL: nil)
        _ = await pollUntil { !web.isLoading }
        let router = BridgeRouter(chromeWebView: web)
        func count() async -> Int? { try? await web.evaluateJavaScript("got.length") as? Int }
        router.send(event: "first", data: ["title": "Café 日本語 🎉 \"quoted\" \\ </script>", "rows": [["n": 1, "on": true]]])
        _ = await pollUntil { await count() == 1 }
        // NaN is not JSON: this one crosses as objects.
        router.send(event: "second", data: ["ratio": Double.nan])
        router.send(event: "third", data: ["none": NSNull()])
        let arrived = await pollUntil { await count() == 3 }
        XCTAssertTrue(arrived)
        let summary = try await web.evaluateJavaScript("""
            JSON.stringify([got[0].event, got[0].title, got[0].rows[0].n, got[0].rows[0].on, Number.isNaN(got[1].ratio), got[2].none, got[2].event])
            """) as? String
        XCTAssertEqual(summary, #"["first","Café 日本語 🎉 \"quoted\" \\ </script>",1,true,true,null,"third"]"#)
    }
}
