import XCTest
@testable import Lilo

final class SpaceTabStateTests: XCTestCase {

    /// `durableRevision` must change exactly when the encoded bytes change: a missed bump loses a save, a spurious one
    /// wastes one.
    @MainActor
    func testDurableRevisionTracksEncodedBytesExactly() throws {
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: nil, activationHistory: [], tree: .empty
        ))
        let a = Tab(id: UUID(), title: "A", spaceId: session.spaceId)
        session.createTab(a, activate: true)
        let b = Tab(id: UUID(), title: "B", spaceId: session.spaceId)
        session.createTab(b, activate: false)
        let aId = a.id
        let bId = b.id

        let mutations: [(String, (inout SpaceTab) -> Void)] = [
            ("content title", { s in var t = s.tab(id: aId)!; t.title = "T1"; s.updateTab(t) }),
            ("content url", { s in var t = s.tab(id: aId)!; t.url = URL(string: "https://example.org"); s.updateTab(t) }),
            ("identical no-op", { s in let t = s.tab(id: aId)!; s.updateTab(t) }),
            ("activation", { s in s.activateTab(bId) }),
            ("re-activate same (no-op)", { s in s.activateTab(bId) }),
            ("pin (structural)", { s in s.setPinned(aId, pinned: true) }),
            ("create tab", { s in s.createTab(Tab(id: UUID(), title: "C", spaceId: s.spaceId), activate: false) })
        ]

        for (label, mutate) in mutations {
            let bytesBefore = try SpaceTabStateCodec.encode(session.state)
            let revBefore = session.durableRevision
            mutate(&session)
            let bytesAfter = try SpaceTabStateCodec.encode(session.state)
            XCTAssertEqual(
                session.durableRevision != revBefore,
                bytesBefore != bytesAfter,
                "[\(label)] durableRevision-changed must equal encoded-bytes-changed"
            )
        }
    }

    func testTreeStateRoundTripsThroughBinaryPropertyList() throws {
        let activeTabId = UUID()
        let childTabId = UUID()
        let folderId = UUID()
        let state = SpaceTabState(
            version: 1,
            activeTabId: activeTabId,
            activationHistory: [childTabId],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .folder(StoredFolder(
                        id: folderId,
                        name: "Work",
                        color: "#123456",
                        isCollapsed: false,
                        children: [
                            .tab(Self.storedTab(
                                id: childTabId,
                                url: "https://child.example",
                                title: "Child"
                            ))
                        ]
                    )),
                    .tab(Self.storedTab(
                        id: activeTabId,
                        url: "https://active.example",
                        title: "Active"
                    ))
                ],
                bookmarked: []
            )
        )

        let data = try SpaceTabStateCodec.encode(state)
        let decoded = try SpaceTabStateCodec.decode(data)

        XCTAssertEqual(decoded, state)
    }

    func testRepairDropsInvalidActiveTabAndMRU() {
        let missingTabId = UUID()
        let openTabId = UUID()
        let state = SpaceTabState(
            version: 1,
            activeTabId: missingTabId,
            activationHistory: [missingTabId, openTabId, openTabId],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .tab(Self.storedTab(
                        id: openTabId,
                        url: "https://open.example",
                        title: "Open"
                    ))
                ],
                bookmarked: []
            )
        )

        let repaired = SpaceTabStateRepair.repaired(state)

        XCTAssertNil(repaired.activeTabId)
        XCTAssertEqual(repaired.activationHistory, [openTabId])
    }

    func testProjectedImportBuildsRecursiveFolderTree() {
        let spaceId = UUID()
        let folderId = UUID()
        let tabId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#123456", isCollapsed: true)
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Nested", groupId: folderId, spaceId: spaceId)
        let state = SpaceTabStateImporter.importState(
            activeTabId: tabId,
            activationHistory: [],
            tabs: [tab],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0)
            ],
            spaceId: spaceId
        )

        guard case let .folder(storedFolder)? = state.tree.unpinned.first else {
            return XCTFail("Expected root folder")
        }
        guard case let .tab(storedTab)? = storedFolder.children.first else {
            return XCTFail("Expected child tab")
        }

        XCTAssertEqual(storedFolder.id, folderId)
        XCTAssertEqual(storedFolder.name, "Folder")
        XCTAssertTrue(storedFolder.isCollapsed)
        XCTAssertEqual(storedTab.id, tabId)
        XCTAssertNil(storedTab.homeURL)
    }

    func testProjectionReconstructsTreeOrder() {
        let spaceId = UUID()
        let folderId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let state = SpaceTabState(
            activeTabId: firstTabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .folder(StoredFolder(
                        id: folderId,
                        name: "Folder",
                        color: "#123456",
                        isCollapsed: false,
                        children: [
                            .tab(Self.storedTab(id: firstTabId, url: "https://first.example", title: "First")),
                            .tab(Self.storedTab(id: secondTabId, url: "https://second.example", title: "Second"))
                        ]
                    ))
                ],
                bookmarked: []
            )
        )

        let projection = state.projectedSidebar(spaceId: spaceId)
        let tabs = projection.tabs
        let folders = projection.folders
        let treeItems = projection.treeItems

        XCTAssertEqual(folders.map(\.id), [folderId])
        XCTAssertEqual(tabs.map(\.id), [firstTabId, secondTabId])
        XCTAssertEqual(tabs.map(\.groupId), [folderId, folderId])
        XCTAssertEqual(treeItems.map(\.kind), [.folder, .tab, .tab])
        XCTAssertEqual(treeItems.map(\.itemId), [folderId, firstTabId, secondTabId])
        XCTAssertEqual(treeItems.map(\.parentFolderId), [nil, folderId, folderId])
        XCTAssertEqual(treeItems.map(\.sortOrder), [0, 0, 1])
    }

    func testProjectedImportDropsOrphanTreeItemAndSynthesizesVisibleTab() {
        let spaceId = UUID()
        let orphanFolderId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, title: "Visible", spaceId: spaceId)
        let state = SpaceTabStateImporter.importState(
            activeTabId: nil,
            activationHistory: [],
            tabs: [tab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: orphanFolderId, section: .unpinned, sortOrder: 0)
            ],
            spaceId: spaceId
        )

        XCTAssertEqual(state.tree.unpinned.map(\.id), [tabId])
    }

    func testProjectionPreservesBookmarkedTabSection() {
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, title: "Bookmark", isBookmarked: true, spaceId: spaceId)
        let state = SpaceTabStateImporter.importState(
            activeTabId: tabId,
            activationHistory: [],
            tabs: [tab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .bookmarked, sortOrder: 0)
            ],
            spaceId: spaceId
        )

        XCTAssertEqual(state.tree.bookmarked.map(\.id), [tabId])
        let projection = state.projectedSidebar(spaceId: spaceId)
        XCTAssertEqual(projection.treeItems.map(\.section), [.bookmarked])
        XCTAssertEqual(projection.tabs.first?.isBookmarked, true)
    }

    func testEncodedBlobOmitsFaviconDataURLs() throws {
        let payload = "data:image/png;base64,QUFBQUFBQUFBQUFBQUFBQQ=="
        var tab = Self.storedTab(id: UUID(), url: "https://example.com", title: "Example")
        tab.faviconDataURL = payload
        tab.faviconDominantColor = "#336699"
        tab.homeURL = "https://example.com"
        tab.homeFaviconDataURL = payload
        tab.homeFaviconDominantColor = "#123456"
        let state = SpaceTabState(
            activeTabId: tab.id,
            activationHistory: [],
            tree: StoredSidebarTree(pinned: [], unpinned: [.tab(tab)], bookmarked: [])
        )

        let data = try SpaceTabStateCodec.encode(state)

        XCTAssertNil(data.range(of: Data(payload.utf8)))
        XCTAssertNil(data.range(of: Data("base64,".utf8)))

        guard case let .tab(decoded)? = try SpaceTabStateCodec.decode(data).tree.unpinned.first else {
            return XCTFail("expected a tab node")
        }
        XCTAssertNil(decoded.faviconDataURL)
        XCTAssertNil(decoded.homeFaviconDataURL)
        XCTAssertEqual(decoded.faviconDominantColor, "#336699")
        XCTAssertEqual(decoded.homeFaviconDominantColor, "#123456")
    }

    func testEncodedBlobSizeDropFor200TabState() throws {
        var nodes: [StoredSidebarNode] = []
        for index in 0..<200 {
            var tab = Self.storedTab(id: UUID(), url: "https://site\(index).example.com", title: "Site \(index)")
            tab.faviconDominantColor = "#336699"
            nodes.append(.tab(tab))
        }
        let state = SpaceTabState(
            activeTabId: nodes.first?.id,
            activationHistory: [],
            tree: StoredSidebarTree(pinned: [], unpinned: nodes, bookmarked: [])
        )

        let slim = try SpaceTabStateCodec.encode(state)
        // Per-tab payloads must be distinct or binary-plist string uniquing collapses them.
        let embedded = try Self.blobWithEmbeddedFavicons(from: state) { index in
            "data:image/png;base64,tab\(index)" + String(repeating: "A", count: 777)
        }

        XCTAssertNotNil(try SpaceTabStateCodec.decode(embedded))
        XCTAssertLessThan(slim.count * 4, embedded.count, "\(embedded.count) bytes with embedded favicons, \(slim.count) without")
    }

    /// Rewrites an encoded blob with a favicon data URL embedded on every root unpinned tab.
    private static func blobWithEmbeddedFavicons(
        from state: SpaceTabState,
        faviconDataURL: (Int) -> String
    ) throws -> Data {
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: SpaceTabStateCodec.encode(state), format: nil
        ) as? [String: Any])
        var tree = try XCTUnwrap(root["tree"] as? [String: Any])
        var unpinned = try XCTUnwrap(tree["unpinned"] as? [[String: Any]])
        for index in unpinned.indices {
            var node = try XCTUnwrap(unpinned[index]["tab"] as? [String: Any])
            var tab = try XCTUnwrap(node["_0"] as? [String: Any])
            tab["faviconDataURL"] = faviconDataURL(index)
            node["_0"] = tab
            unpinned[index]["tab"] = node
        }
        tree["unpinned"] = unpinned
        root["tree"] = tree
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private static func storedTab(
        id: UUID,
        url: String?,
        title: String,
        isPinned: Bool = false,
        isBookmarked: Bool = false,
        isClosed: Bool = false
    ) -> StoredTab {
        StoredTab(
            id: id,
            url: url,
            title: title,
            faviconDataURL: nil,
            faviconDominantColor: nil,
            isPinned: isPinned,
            isBookmarked: isBookmarked,
            isClosed: isClosed,
            homeURL: nil,
            homeTitle: nil,
            homeFaviconDataURL: nil,
            homeFaviconDominantColor: nil
        )
    }
}
