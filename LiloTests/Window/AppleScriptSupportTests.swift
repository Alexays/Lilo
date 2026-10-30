import AppKit
import XCTest
@testable import Lilo

@MainActor
final class AppleScriptSupportTests: XCTestCase {
    func testDictionaryMapsTabsOntoTheScriptingClass() throws {
        let registry = NSScriptSuiteRegistry.shared()
        let tab = try XCTUnwrap(registry.classDescription(withAppleEventCode: FourCharCode(fourCharString: "LiTb")),
                                "Lilo.sdef must ship in the bundle and declare the tab class")
        XCTAssertEqual(tab.className, "tab")
        XCTAssertTrue(NSClassFromString("LiloScriptTab") == ScriptTab.self)
        XCTAssertNotNil(tab.type(forKey: "scriptURL"))
    }

    func testAWindowShowingAPrivateSpaceHasNoTabsForScripts() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let regular = try context.spaceManager.createSpace(name: "R", profileId: profileId)
        let secret = try context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: true)
        let window = MainWindowController(context: context)
        defer { window.window?.close() }
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        window.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        context.windows.add(window)
        let nsWindow = try XCTUnwrap(window.window)

        window.switchToSpace(regular.id)
        _ = window.createTabStateFirst(url: URL(string: "https://example.com/"), activate: true)
        XCTAssertEqual(nsWindow.scriptTabs.map(\.scriptURL), ["https://example.com/"])

        window.switchToSpace(secret.id)
        let hidden = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://secret.example/"), activate: true))
        XCTAssertTrue(nsWindow.scriptTabs.isEmpty)
        XCTAssertNil(nsWindow.scriptActiveTab)
        XCTAssertNil(nsWindow.valueInScriptTabsWithUniqueID(hidden.id.uuidString))
    }

    func testALockedFolderKeepsItsTabsFromScripts() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "R", profileId: profileId)
        let window = MainWindowController(context: context)
        defer { window.window?.close() }
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        window.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        context.windows.add(window)
        let nsWindow = try XCTUnwrap(window.window)
        window.switchToSpace(space.id)
        _ = window.createTabStateFirst(url: URL(string: "https://example.com/"), activate: true)
        let bank = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://bank.example/"), activate: true))
        let folder = TabFolder(spaceId: space.id, name: "Finances")
        window.applyContextMenuStateCommands([
            .createFolder(spaceId: space.id, folder: folder, section: .unpinned),
            .moveSidebarItem(spaceId: space.id, kind: .tab, itemId: bank.id, parentFolderId: folder.id, section: .unpinned, insert: .index(0)),
            .setFolderLock(spaceId: space.id, folderId: folder.id, lock: FolderLock(allowsBiometrics: false))
        ])
        XCTAssertEqual(window.tabManager.activeTabId, bank.id)

        XCTAssertEqual(nsWindow.scriptTabs.map(\.scriptURL), ["https://example.com/"])
        XCTAssertNil(nsWindow.scriptActiveTab)
        XCTAssertEqual(nsWindow.scriptActiveTabIndex, 0)
        XCTAssertNil(nsWindow.valueInScriptTabsWithUniqueID(bank.id.uuidString))

        _ = ScriptTab(tabId: bank.id, owner: window).handleCloseScriptCommand(NSScriptCommand())
        XCTAssertNotNil(window.tabManager.tab(for: bank.id), "a locked tab cannot be closed without the password")
    }
}

private extension FourCharCode {
    init(fourCharString: String) {
        self = fourCharString.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
