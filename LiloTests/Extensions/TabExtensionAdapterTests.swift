import XCTest
import WebKit
@testable import Lilo

@MainActor
final class TabExtensionAdapterTests: XCTestCase {

    func testIsPrivateFalseForNonPrivateTab() {
        let webView = WKWebView()
        let engineTab = WKWebViewTab(id: UUID(), webView: webView)
        let adapter = TabExtensionAdapter(engineTab: engineTab)
        // A web view on the default (non-private) data store is not private browsing.
        XCTAssertEqual(adapter.engineTab?.isPrivateBrowsing, false)
    }

    /// An extension scripting a frozen tab must get an error, not reach a suspended web view that raises.
    func testAFrozenTabLendsExtensionsNoWebView() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-frozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Tab", "version": "1.0"])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let engineTab = WKWebViewTab(configuration: WKWebViewConfiguration())
        engineTab.wkWebView.loadHTMLString("<p>page</p>", baseURL: nil as URL?)
        let loaded = await pollUntil { (try? await engineTab.wkWebView.evaluateJavaScript("document.body.textContent")) as? String == "page" }
        XCTAssertTrue(loaded)
        let adapter = TabExtensionAdapter(engineTab: engineTab)

        engineTab.freeze()
        XCTAssertNil(adapter.webView(for: context))

        engineTab.reload()
        XCTAssertIdentical(adapter.webView(for: context), engineTab.wkWebView, "a woken tab lends its web view again")
        engineTab.freeze()
        XCTAssertFalse(engineTab.isFrozen, "a tab an extension is scripting stays live until its script has run")
        engineTab.lentToExtensionAt = Date().addingTimeInterval(-3)
        engineTab.freeze()
        XCTAssertTrue(engineTab.isFrozen)
        engineTab.teardown()
    }

    func testANewTabHasNoURLUntilItsFirstNavigationStarts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Tab", "version": "1.0"])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let server = try await TinyHTTPServer(index: "<p>page</p>")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        let engineTab = WKWebViewTab(id: UUID(), webView: WKWebView())
        let adapter = TabExtensionAdapter(engineTab: engineTab)

        XCTAssertNil(adapter.url(for: context), "Chrome reports no url before a tab's first navigation")
        engineTab.loadURL(url)
        XCTAssertEqual(adapter.url(for: context), url)
        let committed = await pollUntil { engineTab.hasCommittedContent && !engineTab.isLoading }
        XCTAssertTrue(committed)
        XCTAssertEqual(adapter.url(for: context), url)
    }

    func testALockedFolderTabShowsExtensionsNoURLOrTitle() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Tab", "version": "1.0"])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        var lockedFolder = TabFolder(spaceId: spaceId, name: "Private")
        lockedFolder.lock = FolderLock(allowsBiometrics: false)
        var inside = Tab(url: URL(string: "https://example.com/inside"), title: "Inside", spaceId: spaceId)
        inside.groupId = lockedFolder.id
        let outside = Tab(url: URL(string: "https://example.com/outside"), title: "Outside", spaceId: spaceId)
        let state = try BrowserStateFixture(
            spaceId: spaceId, activeTabId: outside.id, tabs: [inside, outside], folders: [lockedFolder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: outside.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: lockedFolder.id, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: inside.id, parentFolderId: lockedFolder.id, section: .unpinned, sortOrder: 0)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        let insideAdapter = TabExtensionAdapter(tabId: inside.id, engineTab: nil)
        insideAdapter.tabManager = tabManager
        let outsideAdapter = TabExtensionAdapter(tabId: outside.id, engineTab: nil)
        outsideAdapter.tabManager = tabManager

        XCTAssertNil(insideAdapter.url(for: context))
        XCTAssertNil(insideAdapter.title(for: context))
        XCTAssertEqual(outsideAdapter.url(for: context), outside.url)
        XCTAssertEqual(outsideAdapter.title(for: context), "Outside")
    }
}
