import AppKit
import XCTest
@testable import Lilo

/// Control-Tab: the window's tabs by last use across its Spaces, and the keys that drive the switcher.
@MainActor
final class RecentTabsTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var work: Space!
    private var play: Space!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        work = try context.spaceManager.createSpace(name: "Work", profileId: profileId)
        play = try context.spaceManager.createSpace(name: "Play", profileId: profileId)
    }

    override func tearDown() {
        KeyboardShortcuts.applyPreset("lilo", store: nil)
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func makeWindow() -> MainWindowController {
        let window = MainWindowController(context: browserContext.context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        window.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        browserContext.context.windows.add(window)
        return window
    }

    private func openTab(_ host: String, in window: MainWindowController) throws -> UUID {
        try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://\(host).example"))).id
    }

    private func rowIds(_ window: MainWindowController) -> [String] {
        window.recentTabRows().compactMap { $0["id"] as? String }
    }

    private func key(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 48, in window: MainWindowController) -> NSEvent {
        let characters = keyCode == 48 ? "\t" : keyCode == 53 ? "\u{1b}" : "a"
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window.window!.windowNumber, context: nil, characters: type == .flagsChanged ? "" : characters,
                                charactersIgnoringModifiers: type == .flagsChanged ? "" : characters, isARepeat: false, keyCode: keyCode)!
    }

    /// Work holds a, b and Play holds c, visited a, c, b: b is current, then c, then a.
    private func visitAcrossSpaces(_ window: MainWindowController) throws -> (a: UUID, b: UUID, c: UUID) {
        window.switchToSpace(work.id)
        let a = try openTab("a", in: window)
        let b = try openTab("b", in: window)
        window.activateTabStateFirst(id: a)
        window.switchToSpace(play.id)
        let c = try openTab("c", in: window)
        window.switchToRecentTab(b)
        return (a, b, c)
    }

    func testRowsListTheWindowsTabsByLastUseAcrossSpacesCurrentFirst() throws {
        let window = makeWindow()
        let (a, b, c) = try visitAcrossSpaces(window)

        XCTAssertEqual(window.tabManager.currentSpaceId, work.id)
        XCTAssertEqual(Array(rowIds(window).prefix(3)), [b, c, a].map(\.uuidString))
        let rows = window.recentTabRows()
        XCTAssertEqual(rows[1]["spaceName"] as? String, "Play")
        XCTAssertEqual(rows[0]["leftAt"] as? Double, 0, "the current tab was never left")
        XCTAssertGreaterThan(rows[1]["leftAt"] as? Double ?? 0, 0)
    }

    func testAQuickSwitchGoesBackAndForthBetweenTheLastTwoTabsAcrossSpaces() throws {
        let window = makeWindow()
        let (_, b, c) = try visitAcrossSpaces(window)

        window.switchToRecentTab(c)

        XCTAssertEqual(window.tabManager.currentSpaceId, play.id)
        XCTAssertEqual(Array(rowIds(window).prefix(2)), [c, b].map(\.uuidString), "the Space switch's own tab never comes between them")
    }

    func testClosedTabsAndPrivateAndAgentsSpacesAreLeftOut() throws {
        let window = makeWindow()
        let context = browserContext.context
        let agents = try context.spaceManager.createSpace(name: "Agents", profileId: work.profileId)
        context.settingsStore?.set(AgentControl.agentsSpaceKey, value: agents.id.uuidString)
        let secret = try context.spaceManager.createSpace(name: "Private", profileId: work.profileId, isPrivate: true)
        window.switchToSpace(agents.id)
        let agentTab = try openTab("agent", in: window)
        window.switchToSpace(secret.id)
        let privateTab = try openTab("private", in: window)
        window.switchToSpace(work.id)
        let kept = try openTab("kept", in: window)
        let closed = try openTab("closed", in: window)
        window.closeTabStateFirst(id: closed, undoable: false)

        let ids = rowIds(window)
        XCTAssertTrue(ids.contains(kept.uuidString))
        for id in [closed, agentTab, privateTab] { XCTAssertFalse(ids.contains(id.uuidString)) }

        window.switchToSpace(agents.id)
        XCTAssertTrue(Set([agentTab, kept].map(\.uuidString)).isSubset(of: rowIds(window)), "the Agents space lists its tabs with the others")

        window.switchToSpace(secret.id)
        XCTAssertTrue(rowIds(window).contains(privateTab.uuidString))
        XCTAssertFalse(rowIds(window).contains(kept.uuidString), "a private Space lists only its own")
    }

    func testControlTabOpensTheSwitcherKeepsItsKeysAndReleasingControlClosesIt() throws {
        let window = makeWindow()
        _ = try visitAcrossSpaces(window)

        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, in: window)))
        XCTAssertEqual(window.tabSwitcherModifiers, .control)
        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyUp, .control, in: window)), "the page never sees the Tab")
        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, [.control, .shift], in: window)))
        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, keyCode: 0, in: window)), "nor any other key")
        _ = window.handleMonitoredKeyboardEvent(key(.flagsChanged, [.control, .shift], keyCode: 56, in: window))
        XCTAssertEqual(window.tabSwitcherModifiers, .control, "Shift is not the held key")

        _ = window.handleMonitoredKeyboardEvent(key(.flagsChanged, [], keyCode: 59, in: window))

        XCTAssertNil(window.tabSwitcherModifiers)
    }

    func testEscapeAndFocusLossCloseTheSwitcher() throws {
        let window = makeWindow()
        _ = try visitAcrossSpaces(window)
        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, in: window)))

        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, keyCode: 53, in: window)))
        XCTAssertNil(window.tabSwitcherModifiers)

        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, in: window)))
        window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertNil(window.tabSwitcherModifiers)
    }

    func testAKeyAfterAMissedReleaseClosesTheSwitcherAndGoesOn() throws {
        let window = makeWindow()
        _ = try visitAcrossSpaces(window)
        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, in: window)))

        _ = window.handleMonitoredKeyboardEvent(key(.keyDown, [], keyCode: 0, in: window))

        XCTAssertNil(window.tabSwitcherModifiers)
    }

    func testOneTabOpensNoSwitcher() throws {
        let window = makeWindow()
        window.switchToSpace(work.id)
        _ = try openTab("only", in: window)

        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, in: window)))

        XCTAssertNil(window.tabSwitcherModifiers)
    }

    func testSidebarOrderGivesControlTabBackToTheNextTab() throws {
        let window = makeWindow()
        window.switchToSpace(work.id)
        let first = try openTab("first", in: window)
        _ = try openTab("second", in: window)
        window.activateTabStateFirst(id: first)

        KeyboardShortcuts.setControlTabOrder(recent: false, store: nil)
        XCTAssertEqual(KeyboardShortcuts.bridgePayload["controlTabOrder"] as? String, "sidebar")
        XCTAssertTrue(window.handleMonitoredKeyboardEvent(key(.keyDown, .control, in: window)))

        XCTAssertNil(window.tabSwitcherModifiers)
        XCTAssertNotEqual(window.tabManager.activeOpenTabId, first)
    }
}
