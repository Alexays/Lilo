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
}

private extension FourCharCode {
    init(fourCharString: String) {
        self = fourCharString.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
