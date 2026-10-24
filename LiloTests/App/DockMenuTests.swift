import AppKit
import XCTest
@testable import Lilo

/// The Dock menu opens what it names in a window the user can see.
@MainActor
final class DockMenuTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    func testNewTabBringsBackAWindowClosedWhileATerminalRan() throws {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        let nsWindow = try XCTUnwrap(window.window)
        defer { nsWindow.close() }
        // Transparent and off screen, so nothing shows to whoever runs the tests.
        nsWindow.alphaValue = 0
        nsWindow.setFrame(NSRect(x: -20000, y: -20000, width: 800, height: 600), display: false)
        nsWindow.orderOut(nil)
        let delegate = AppDelegate()
        delegate.browserContext.windows.add(window)
        let tabs = window.tabManager.openTabs.count

        let menu = try XCTUnwrap(delegate.applicationDockMenu(NSApp))
        let item = try XCTUnwrap(menu.items.first { $0.title == "New Tab".localized })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        XCTAssertEqual(window.tabManager.openTabs.count, tabs + 1)
        XCTAssertTrue(nsWindow.isVisible, "the new tab shows")
    }
}
