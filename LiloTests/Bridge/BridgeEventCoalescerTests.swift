import XCTest
@testable import Lilo

/// Unit tests for `BridgeEventCoalescer`: merge logic and tabUpdated operation collapsing.
@MainActor
final class BridgeEventCoalescerTests: XCTestCase {

    // MARK: - collapseOperations: same tab + space merge into one field-merged operation

    func test_collapseOperations_sameTabSameSpace_mergesIntoOne() {
        let op1: [String: Any] = [
            "kind": "tabUpdated",
            "spaceId": "space-1",
            "tab": ["id": "tab-A", "url": "https://old.example.com", "isLoading": true] as [String: Any]
        ]
        let op2: [String: Any] = [
            "kind": "tabUpdated",
            "spaceId": "space-1",
            "tab": ["id": "tab-A", "isLoading": false] as [String: Any]
        ]
        let result = BridgeEventCoalescer.collapseOperations([op1, op2])

        XCTAssertEqual(result.count, 1)
        let merged = result[0]
        XCTAssertEqual(merged["kind"] as? String, "tabUpdated")
        XCTAssertEqual(merged["spaceId"] as? String, "space-1")
        let tab = merged["tab"] as? [String: Any]
        // url preserved from op1; isLoading last-wins from op2
        XCTAssertEqual(tab?["id"] as? String, "tab-A")
        XCTAssertEqual(tab?["url"] as? String, "https://old.example.com")
        XCTAssertEqual(tab?["isLoading"] as? Bool, false)
    }

    func test_collapseOperations_sameTabSameSpace_threeOps_mergesIntoOne() {
        let op1: [String: Any] = ["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "t", "title": "A", "url": "https://a.example"] as [String: Any]]
        let op2: [String: Any] = ["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "t", "title": "B"] as [String: Any]]
        let op3: [String: Any] = ["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "t", "isLoading": false] as [String: Any]]
        let result = BridgeEventCoalescer.collapseOperations([op1, op2, op3])

        XCTAssertEqual(result.count, 1)
        let tab = result[0]["tab"] as? [String: Any]
        XCTAssertEqual(tab?["title"] as? String, "B")     // op2 wins over op1
        XCTAssertEqual(tab?["url"] as? String, "https://a.example")  // preserved from op1
        XCTAssertEqual(tab?["isLoading"] as? Bool, false) // from op3
    }

    // MARK: - collapseOperations: different tabs keep their order, no merge

    func test_collapseOperations_differentTabs_preserved() {
        let op1: [String: Any] = ["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "tab-A", "url": "https://a.example"] as [String: Any]]
        let op2: [String: Any] = ["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "tab-B", "url": "https://b.example"] as [String: Any]]
        let result = BridgeEventCoalescer.collapseOperations([op1, op2])

        XCTAssertEqual(result.count, 2)
        let tabA = result[0]["tab"] as? [String: Any]
        let tabB = result[1]["tab"] as? [String: Any]
        XCTAssertEqual(tabA?["id"] as? String, "tab-A")
        XCTAssertEqual(tabB?["id"] as? String, "tab-B")
    }

    func test_collapseOperations_differentSpaces_preserved() {
        let op1: [String: Any] = ["kind": "tabUpdated", "spaceId": "space-1", "tab": ["id": "tab-A"] as [String: Any]]
        let op2: [String: Any] = ["kind": "tabUpdated", "spaceId": "space-2", "tab": ["id": "tab-A"] as [String: Any]]
        let result = BridgeEventCoalescer.collapseOperations([op1, op2])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["spaceId"] as? String, "space-1")
        XCTAssertEqual(result[1]["spaceId"] as? String, "space-2")
    }

    // MARK: - collapseOperations: mixed kinds, structural ops break the collapse run

    func test_collapseOperations_sidebarChangedInterleaved_notCollapsed() {
        let op1: [String: Any] = ["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "t", "url": "https://a.example"] as [String: Any]]
        let structural: [String: Any] = ["kind": "sidebarChanged", "data": "x"]
        let op2: [String: Any] = ["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "t", "url": "https://b.example"] as [String: Any]]
        let result = BridgeEventCoalescer.collapseOperations([op1, structural, op2])

        // The sidebarChanged breaks the consecutive run so op1 and op2 cannot merge.
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]["kind"] as? String, "tabUpdated")
        XCTAssertEqual(result[1]["kind"] as? String, "sidebarChanged")
        XCTAssertEqual(result[2]["kind"] as? String, "tabUpdated")
    }

    // MARK: - trackersBlockedChanged: singleton coalescing

    func test_coalescingTabId_trackersBlockedChanged_isSingleton() {
        XCTAssertEqual(
            BridgeEventCoalescer.coalescingTabId(for: "trackersBlockedChanged", data: ["count": 3]),
            "trackersBlockedChanged",
            "trackersBlockedChanged carries no tab id and must coalesce under a singleton key"
        )
    }

    func test_add_trackersBlockedChanged_lastWriteWins() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "trackersBlockedChanged", data: ["count": 1]),
                      "trackersBlockedChanged must be coalescable, not a raw send that force-flushes patches")
        XCTAssertTrue(coalescer.add(event: "trackersBlockedChanged", data: ["count": 7]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].event, "trackersBlockedChanged")
        XCTAssertEqual(drained[0].data["count"] as? Int, 7)
    }

    func test_add_terminalActivity_lastWriteWins() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "terminalActivity", data: ["terminals": [["tabId": "a", "state": "busy"]]]))
        XCTAssertTrue(coalescer.add(event: "terminalActivity", data: ["terminals": [["tabId": "b", "state": "idle"]]]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        let terminals = drained[0].data["terminals"] as? [[String: String]]
        XCTAssertEqual(terminals, [["tabId": "b", "state": "idle"]])
    }

    func test_add_extensionsChanged_mergesRowsByIdAndKeepsBufferedIcon() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "extensionsChanged", data: [
            "ids": ["a", "b"],
            "extensions": [["id": "a", "badgeText": "1", "iconDataURL": "data:image/png;base64,A"], ["id": "b", "badgeText": ""]]
        ]))
        XCTAssertTrue(coalescer.add(event: "extensionsChanged", data: [
            "ids": ["a", "b"],
            "extensions": [["id": "a", "badgeText": "2"]]
        ]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        let rows = Dictionary(uniqueKeysWithValues: (drained[0].data["extensions"] as? [[String: Any]] ?? []).map { ($0["id"] as? String, $0) })
        XCTAssertEqual(rows["a"]?["badgeText"] as? String, "2")
        XCTAssertEqual(rows["a"]?["iconDataURL"] as? String, "data:image/png;base64,A",
                       "a later delta that leaves the icon out as unchanged must not drop the buffered one")
        XCTAssertEqual(rows["b"]?["badgeText"] as? String, "", "a row only the earlier delta carried survives the merge")
    }

    // MARK: - downloadUpdated: keyed per download, snapshot semantics

    func test_add_downloadUpdated_keyedPerDownload() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "downloadUpdated", data: ["id": Int64(1), "bytesReceived": Int64(10)]),
                      "progress ticks must coalesce, not force-flush pending patches once per tick")
        XCTAssertTrue(coalescer.add(event: "downloadUpdated", data: ["id": Int64(1), "bytesReceived": Int64(90)]))
        XCTAssertTrue(coalescer.add(event: "downloadUpdated", data: ["id": Int64(2), "bytesReceived": Int64(5)]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 2, "one payload per download, not per tick")
        let byId = Dictionary(uniqueKeysWithValues: drained.map { ($0.data["id"] as? Int64, $0.data) })
        XCTAssertEqual(byId[1]?["bytesReceived"] as? Int64, 90)
        XCTAssertEqual(byId[2]?["bytesReceived"] as? Int64, 5)
    }

    func test_add_downloadUpdated_laterPayloadReplacesRatherThanMerges() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "downloadUpdated",
                                    data: ["id": Int64(1), "state": "inProgress", "speedBytesPerSec": Int64(5_000)]))
        XCTAssertTrue(coalescer.add(event: "downloadUpdated", data: ["id": Int64(1), "state": "complete"]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].data["state"] as? String, "complete")
        XCTAssertNil(drained[0].data["speedBytesPerSec"],
                     "a full snapshot replaces the buffered one: a finished download keeps no stale speed")
    }

    func test_coalescingTabId_downloadUpdated_withoutId_isNotCoalescable() {
        XCTAssertNil(BridgeEventCoalescer.coalescingTabId(for: "downloadUpdated", data: ["state": "complete"]))
    }

    // MARK: - add / drain integration

    func testCoalescerConcatenatesOperationsForSameTab() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "browserStatePatch",
                                    data: ["operations": [["tab": ["id": "tab-1"], "url": "https://a.test"]]]))
        XCTAssertTrue(coalescer.add(event: "browserStatePatch",
                                    data: ["operations": [["tab": ["id": "tab-1"], "isLoading": false]]]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual((drained.first?.data["operations"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(coalescer.drain().isEmpty)
    }

    func testCoalescerKeepsDistinctTabsSeparate() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: ["operations": [["tab": ["id": "tab-1"]]]]))
        XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: ["operations": [["tab": ["id": "tab-2"]]]]))

        XCTAssertEqual(coalescer.drain().count, 2)
    }

    func testCoalescerScalarSurvivesLaterDelta() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: ["tabId": "t", "url": "https://a.test"]))
        XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: ["tabId": "t", "isLoading": false]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.data["url"] as? String, "https://a.test")
        XCTAssertEqual(drained.first?.data["isLoading"] as? Bool, false)
    }

    func testCoalescingTabIdNilWhenOperationsSpanTwoTabs() {
        XCTAssertNil(BridgeEventCoalescer.coalescingTabId(
            for: "browserStatePatch",
            data: ["operations": [["tab": ["id": "a"]], ["tab": ["id": "b"]]]]))
    }

    func testNonCoalescingEventIsNotBuffered() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertFalse(coalescer.add(event: "someOtherEvent", data: ["id": "x"]))
        XCTAssertTrue(coalescer.drain().isEmpty)
    }

    func test_add_browserStatePatch_sameTab_mergesAndCollapses() {
        var coalescer = BridgeEventCoalescer()
        let data1: [String: Any] = [
            "operations": [["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "t", "url": "https://a.example"] as [String: Any]] as [String: Any]]
        ]
        let data2: [String: Any] = [
            "operations": [["kind": "tabUpdated", "spaceId": "s", "tab": ["id": "t", "isLoading": false] as [String: Any]] as [String: Any]]
        ]
        XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: data1))
        XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: data2))
        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        let ops = drained[0].data["operations"] as? [[String: Any]]
        XCTAssertEqual(ops?.count, 1, "two tabUpdated ops for the same tab must collapse to one")
        let tab = ops?[0]["tab"] as? [String: Any]
        XCTAssertEqual(tab?["url"] as? String, "https://a.example")
        XCTAssertEqual(tab?["isLoading"] as? Bool, false)
    }

    func test_drain_patchesOfOneSpace_shipAsOnePatch() {
        var coalescer = BridgeEventCoalescer()
        for tabId in ["t1", "t2"] {
            XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: [
                "changedSpaceId": "s",
                "operations": [["kind": "tabUpdated", "spaceId": "s", "tab": ["id": tabId] as [String: Any]] as [String: Any]]
            ]))
        }
        XCTAssertTrue(coalescer.add(event: "browserStatePatch", data: [
            "changedSpaceId": "other",
            "operations": [["kind": "tabUpdated", "spaceId": "other", "tab": ["id": "t3"] as [String: Any]] as [String: Any]]
        ]))

        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 2, "one patch per space")
        let tabIdsBySpace = Dictionary(uniqueKeysWithValues: drained.map { pair in
            (pair.data["changedSpaceId"] as? String ?? "",
             Set((pair.data["operations"] as? [[String: Any]] ?? []).compactMap { ($0["tab"] as? [String: Any])?["id"] as? String }))
        })
        XCTAssertEqual(tabIdsBySpace, ["s": ["t1", "t2"], "other": ["t3"]])
    }

    func test_add_commandKeyChanged_lastWriteWins() {
        var coalescer = BridgeEventCoalescer()
        XCTAssertTrue(coalescer.add(event: "commandKeyChanged", data: ["down": true]))
        XCTAssertTrue(coalescer.add(event: "commandKeyChanged", data: ["down": false]))
        let drained = coalescer.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].data["down"] as? Bool, false)
    }
}
