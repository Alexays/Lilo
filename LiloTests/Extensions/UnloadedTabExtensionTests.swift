import WebKit
import XCTest
@testable import Lilo

/// A tab listed to extensions before it has a page keeps its id once it loads, and its content scripts reach the worker.
@MainActor
final class UnloadedTabExtensionTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var server: TinyHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        server = try await TinyHTTPServer(index: "<title>Page</title><p>page</p>")
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        server = nil
        super.tearDown()
    }

    /// An extension whose content script marks its page with the worker's answers: the sender tab id, whether the worker's
    /// first `tabs.query` listed that tab as discarded, and the same for each `onCreated` announcing it.
    private func loadMessagingExtension(in registry: ProfileExtensionRegistry) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unloaded-tab-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Messenger", "version": "1.0",
            "host_permissions": ["<all_urls>"], "background": ["service_worker": "background.js"],
            "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"]]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try """
        const mark = (key, value) => { document.documentElement.dataset[key] = value; };
        chrome.runtime.sendMessage('hello').then((reply) => mark('message', String(reply)), (error) => mark('message', `error: ${error.message}`));
        chrome.runtime.connect().onMessage.addListener((reply) => mark('port', String(reply)));
        """.write(to: folder.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        try """
        const listed = chrome.tabs.query({}).then((tabs) => Object.fromEntries(tabs.map((tab) => [tab.id, tab.discarded])));
        const created = {};
        chrome.tabs.onCreated.addListener(async (tab) => {
          const queried = (await chrome.tabs.query({})).find((each) => each.id === tab.id);
          (created[tab.id] ??= []).push(String(queried?.discarded));
        });
        chrome.runtime.onMessage.addListener((message, sender, reply) => {
          const id = sender.tab?.id;
          listed.then((tabs) => reply(`${id} listed:${tabs[id]} created:${(created[id] ?? []).join(',')}`));
          return true;
        });
        chrome.runtime.onConnect.addListener((port) => port.postMessage(String(port.sender?.tab?.id)));
        """.write(to: folder.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        _ = await registry.backgrounds.load(id)
    }

    /// The page's marks once both the message and the port answered.
    private func marks(_ window: MainWindowController, _ tabId: UUID) async throws -> (message: String, port: String) {
        var marks = ["", ""]
        let answered = await pollUntil(timeout: 10) {
            guard let webView = window.tabManager.engineTab(for: tabId)?.wkWebView else { return false }
            let dataset = "document.documentElement.dataset"
            marks = (try? await webView.evaluateJavaScript("[\(dataset).message ?? '', \(dataset).port ?? '']") as? [String]) ?? marks
            return !marks.contains("")
        }
        XCTAssertTrue(answered, "the content script hears back from the worker: \(marks)")
        return (marks[0], marks[1])
    }

    /// A space the window has shown, with an active tab and a background one, both on the test page and never loaded.
    private func makeSpaceWithTwoTabs(_ window: MainWindowController, _ registry: ProfileExtensionRegistry) throws -> (UUID, Tab, Tab) {
        let space = try browserContext.context.spaceManager.createSpace(name: "Other", profileId: registry.profileId)
        let home = try XCTUnwrap(window.tabManager.currentSpaceId)
        window.switchToSpace(space.id)
        window.switchToSpace(home)
        let url = URL(string: "http://127.0.0.1:\(server.port)/")
        let active = Tab(url: url, title: "Page")
        let background = Tab(url: url, title: "Page")
        try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: active, activate: true))
        try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: background, activate: false))
        return (space.id, active, background)
    }

    func testAnUnloadedTabKeepsItsIdAndReachesTheWorkerOnceItLoads() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        try await loadMessagingExtension(in: registry)
        let (spaceId, shown, unloaded) = try makeSpaceWithTwoTabs(window, registry)

        window.switchToSpace(spaceId)
        XCTAssertNil(window.tabManager.engineTab(for: unloaded.id), "the background tab stays unloaded")
        let shownMarks = try await marks(window, shown.id)
        let shownId = try XCTUnwrap(shownMarks.message.split(separator: " ").first.map(String.init))
        XCTAssertNotEqual(shownId, "undefined", "the shown tab's page has its tab: \(shownMarks)")
        XCTAssertEqual(shownMarks.port, shownId)

        window.tabManager.activateTabRuntime(id: unloaded.id)

        let unloadedMarks = try await marks(window, unloaded.id)
        let unloadedId = try XCTUnwrap(unloadedMarks.message.split(separator: " ").first.map(String.init))
        XCTAssertEqual(unloadedMarks.message, "\(unloadedId) listed:undefined created:true", "one onCreated, while tabs.query listed it discarded")
        XCTAssertEqual(unloadedMarks.port, unloadedId)

        // A discarded tab, which had a page, gets its next one under the same id.
        window.tabManager.activateTabRuntime(id: shown.id)
        window.tabManager.discardEngine(unloaded.id)
        window.tabManager.activateTabRuntime(id: unloaded.id)

        let reloadedMarks = try await marks(window, unloaded.id)
        XCTAssertEqual(reloadedMarks.message, unloadedMarks.message)
        XCTAssertEqual(reloadedMarks.port, unloadedId)
    }

    /// As at launch: the window lists its restored tabs, none loaded and its active one not yet activated, when the extension loads.
    func testTabsRestoredBeforeTheExtensionLoadsAreItsTabs() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        let (spaceId, first, second) = try makeSpaceWithTwoTabs(window, registry)
        window.switchToSpace(spaceId, forSessionRestore: true)
        XCTAssertNil(window.tabManager.engineTab(for: first.id))
        try await loadMessagingExtension(in: registry)

        window.tabManager.activateTabRuntime(id: second.id)

        let marks = try await marks(window, second.id)
        let id = try XCTUnwrap(marks.message.split(separator: " ").first.map(String.init))
        XCTAssertEqual(marks.message, "\(id) listed:true created:", "the worker's first tabs.query listed the tab, unloaded, under its id")
        XCTAssertEqual(marks.port, id)
    }
}
