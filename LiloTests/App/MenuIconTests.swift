import XCTest
import WebKit
@testable import Lilo

/// Context menus show an SF Symbol on each action, all or none per section, and grey out what cannot run.
@MainActor
final class MenuIconTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var shownMenu: NSMenu?

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        window = try browserContext.makeExtensionWindow().0
        // Transparent and off screen: the menus pop up there and close at once.
        let nsWindow = try XCTUnwrap(window.window)
        nsWindow.alphaValue = 0
        nsWindow.orderFrontRegardless()
        nsWindow.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 700), display: false)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    override func tearDown() {
        NotificationCenter.default.removeObserver(self)
        window.window?.close()
        window = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu.supermenu == nil else { return }
        shownMenu = menu
        // A cancel sent before the tracking loop runs is lost, so it waits for the loop.
        nonisolated(unsafe) let tracked = menu
        RunLoop.main.perform(inModes: [.eventTracking]) { tracked.cancelTrackingWithoutAnimation() }
    }

    private func popUp(_ show: () -> Void) throws -> NSMenu {
        shownMenu = nil
        show()
        return try XCTUnwrap(shownMenu)
    }

    /// From macOS 27, AppKit hides an item's image unless the item asks to show it.
    private func isShown(_ item: NSMenuItem) -> Bool {
        guard #available(macOS 27, *) else { return true }
        return item.preferredImageVisibility == .visible
    }

    /// Every item but the `plain` ones (names of folders, profiles: choices, not actions) has a
    /// shown icon, submenus included, and a section between separators has icons on all items or none.
    private func assertIcons(_ menu: NSMenu, plain: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        var section: [NSMenuItem] = []
        func endSection() {
            let iconed = section.filter { $0.image != nil }.count
            XCTAssert(iconed == 0 || iconed == section.count, "mixed section: \(section.map(\.title))", file: file, line: line)
            section = []
        }
        for item in menu.items {
            if item.isSeparatorItem {
                endSection()
                continue
            }
            section.append(item)
            if item.image == nil, !plain.contains(item.title) { XCTFail("no icon: \(item.title)", file: file, line: line) }
            if item.image != nil, !isShown(item) { XCTFail("hidden icon: \(item.title)", file: file, line: line) }
            if let submenu = item.submenu { assertIcons(submenu, plain: plain, file: file, line: line) }
        }
        endSection()
    }

    func testEverySymbolExists() {
        for icon in MenuIcon.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil), icon.symbolName)
        }
    }

    /// Lilo's menu bar items get their symbols when the menu opens. AppKit also inserts its own items,
    /// such as Writing Tools, whose appearance it controls.
    func testEveryLiloMainMenuItemHasAnIcon() throws {
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        let delegate = AppDelegate()
        delegate.setupMainMenu()
        var pending = 0
        func countPending(_ menu: NSMenu) {
            pending += menu.items.filter { ($0 as? SymbolMenuItem)?.symbolName != nil }.count
            menu.items.compactMap(\.submenu).forEach(countPending)
        }
        countPending(try XCTUnwrap(NSApp.mainMenu))
        XCTAssertGreaterThan(pending, 0)
        var missing: [String] = []
        func visit(_ menu: NSMenu) {
            // What AppKit calls as the menu opens; a dynamic menu repopulates first, then shows its images the same way.
            if menu.delegate is MenuBarImageLoader { menu.delegate?.menuNeedsUpdate?(menu) } else { menu.showItemImages() }
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if item is SymbolMenuItem, item.image == nil || !isShown(item) { missing.append(item.title) }
                item.submenu.map(visit)
            }
        }
        for top in try XCTUnwrap(NSApp.mainMenu).items { top.submenu.map(visit) }
        XCTAssertEqual(missing, [])
    }

    func testSidebarTabAndFolderMenus() throws {
        let context = browserContext.context
        let spaceId = try XCTUnwrap(window.tabManager.currentSpaceId)
        try context.spaceManager.createSpace(name: "Other", profileId: try XCTUnwrap(context.spaceManager.space(with: spaceId)?.profileId))
        context.settingsStore.set(AgentControl.agentsSpaceKey, value: spaceId.uuidString)
        let folder = TabFolder(spaceId: spaceId, name: "Work")
        window.applyContextMenuStateCommands([.createFolder(spaceId: spaceId, folder: folder, section: .unpinned)])
        let inFolder = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"), activate: false, sidebarParentFolderId: folder.id, sidebarSection: .unpinned, sidebarIndex: 0))
        let pinned = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"), activate: false))
        window.applyContextMenuStateCommands([.setPinned(spaceId: spaceId, tabId: pinned.id, isPinned: true)])
        XCTAssertNotNil(window.createTabStateFirst(url: URL(string: "about:blank")))
        let profiles = Set(context.profileManager.profiles.map(\.name))

        let sidebar = try popUp { window.showSidebarContextMenu(spaceId: nil, anchorRect: nil) }
        XCTAssertTrue(sidebar.items.contains { $0.title == "Delete Space…".localized })
        XCTAssertTrue(sidebar.items.contains { $0.title == "Agents' Profile".localized })
        assertIcons(sidebar, plain: profiles)
        let expected: [String: MenuIcon] = [
            "New Tab": .newTab, "New Terminal Tab": .newTerminalTab, "Create Folder": .newFolder, "Edit Space": .edit,
            "New Space": .newSpace, "Delete Space…": .delete, "Restore Closed Tab": .restoreClosedTab
        ]
        for (title, icon) in expected {
            let item = try XCTUnwrap(sidebar.items.first { $0.title == title.localized }, title)
            XCTAssertTrue(item.image === icon.image, "\(title) shows \(icon.symbolName)")
        }

        let tab = try popUp { window.showTabContextMenu(tabId: inFolder.id.uuidString, anchorRect: nil) }
        XCTAssertTrue(tab.items.contains { $0.title == "Open in Split View".localized })
        let folderMenu = try XCTUnwrap(tab.items.first { $0.title == "Move to Folder".localized }?.submenu)
        XCTAssertTrue(folderMenu.items.contains { $0.title == "Remove from Folder".localized })
        // The Spaces a tab can move to read by their own emoji, as in the Spaces menu.
        let spaceMenu = try XCTUnwrap(tab.items.first { $0.title == "Move to Space".localized }?.submenu)
        let spaces = Set(spaceMenu.items.map(\.title))
        XCTAssertEqual(spaces.count, 1)
        assertIcons(tab, plain: spaces.union([folder.name]))

        assertIcons(try popUp { window.showTabContextMenu(tabId: pinned.id.uuidString, anchorRect: nil) }, plain: spaces.union([folder.name]))
        assertIcons(try popUp { window.showFolderContextMenu(folderId: folder.id.uuidString, anchorRect: nil) })
    }

    func testFolderMenuNewFolderAndCreateFolderFromTabNestAtTheirLevel() throws {
        let spaceId = try XCTUnwrap(window.tabManager.currentSpaceId)
        let folder = TabFolder(spaceId: spaceId, name: "Work", isCollapsed: true)
        window.applyContextMenuStateCommands([.createFolder(spaceId: spaceId, folder: folder, section: .unpinned)])
        let inFolder = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"), activate: false, sidebarParentFolderId: folder.id, sidebarSection: .unpinned, sidebarIndex: 0))
        func run(_ title: String, in menu: NSMenu) throws {
            let item = try XCTUnwrap(menu.items.first { $0.title == title.localized })
            _ = item.target?.perform(item.action, with: item)
        }
        func children(of id: UUID) -> [TabTreeItem] {
            window.tabManager.sidebarTreeItems(forSpace: spaceId).filter { $0.parentFolderId == id }.sorted { $0.sortOrder < $1.sortOrder }
        }

        try run("New Folder", in: try popUp { window.showFolderContextMenu(folderId: folder.id.uuidString, anchorRect: nil) })
        let subfolder = try XCTUnwrap(children(of: folder.id).first)
        XCTAssertEqual(subfolder.kind, .folder)
        XCTAssertEqual(window.tabManager.folder(id: folder.id)?.isCollapsed, false, "the parent opens to show it")

        try run("Create Folder from Tab", in: try popUp { window.showTabContextMenu(tabId: inFolder.id.uuidString, anchorRect: nil) })
        let created = try XCTUnwrap(children(of: folder.id).last)
        XCTAssertEqual(created.kind, .folder)
        XCTAssertEqual(children(of: created.itemId).map(\.itemId), [inFolder.id])
    }

    func testDeletingAFolderForgetsThePasswordsOfTheLockedFoldersInsideIt() throws {
        let spaceId = try XCTUnwrap(window.tabManager.currentSpaceId)
        let outer = TabFolder(spaceId: spaceId, name: "Personal")
        let inner = TabFolder(spaceId: spaceId, name: "Taxes")
        window.applyContextMenuStateCommands([
            .createFolder(spaceId: spaceId, folder: outer, section: .unpinned),
            .createFolder(spaceId: spaceId, folder: inner, section: .unpinned, parentFolderId: outer.id),
            .setFolderLock(spaceId: spaceId, folderId: inner.id, lock: FolderLock(allowsBiometrics: false))
        ])
        XCTAssertTrue(FolderLockKeychain.setPassword("hunter2", folderId: inner.id))
        defer { FolderLockKeychain.remove(folderId: inner.id) }
        // Hidden, the window deletes without asking.
        window.window?.orderOut(nil)

        let deleted = window.deleteFolderAndContent(try XCTUnwrap(window.tabManager.folder(id: outer.id))) { (try? window.applyBrowserCommand($0)) != nil }

        XCTAssertTrue(deleted)
        XCTAssertNil(window.tabManager.folder(id: inner.id))
        XCTAssertFalse(FolderLockKeychain.verify("hunter2", folderId: inner.id))
    }

    func testTabAndSidebarMenusGreyOutWhatCannotRun() throws {
        let terminal = try XCTUnwrap(window.createTerminalTab(activate: true))
        defer { window.tabManager.terminalHost.forget(terminal.id) }

        let menu = try popUp { window.showTabContextMenu(tabId: terminal.id.uuidString, anchorRect: nil) }
        func item(_ title: String) -> NSMenuItem? { menu.items.first { $0.title == title.localized } }
        XCTAssertEqual(item("Duplicate Tab")?.isEnabled, false, "a terminal has no page to duplicate")
        XCTAssertEqual(item("Close Other Tabs")?.isEnabled, false, "no other tab")
        XCTAssertNil(item("Mute Tab"), "a terminal plays no sound")

        let sidebar = try popUp { window.showSidebarContextMenu(spaceId: nil, anchorRect: nil) }
        XCTAssertEqual(sidebar.items.first { $0.title == "Restore Closed Tab".localized }?.isEnabled, false, "nothing was closed")
    }

    func testDownloadAndExtensionMenus() throws {
        for (state, fileMissing) in [("inProgress", false), ("interrupted", false), ("complete", true), ("complete", false)] {
            assertIcons(try popUp { window.showDownloadContextMenu(downloadId: 1, anchorRect: nil, state: state, fileMissing: fileMissing) })
        }
        for pinned in [nil, false, true] {
            assertIcons(try popUp { window.showExtensionContextMenu(extensionId: "missing", anchorRect: nil, pinned: pinned) })
        }
    }

    func testPageLinkAndImageMenus() {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString("", baseURL: URL(string: "https://example.com/"))
        let builder = ContextMenuBuilder(
            webView: webView, onOpenInNewTab: { _ in }, onOpenInPrivateSpace: { _ in }, onOpenInNewWindow: { _ in },
            onTogglePiP: {}, onBookmark: {}, onDownload: { _ in }
        )
        let page = NSMenu()
        builder.build(page, linkURL: nil, extensionItems: [])
        XCTAssertTrue(page.items.contains { $0.title == "Copy Page URL".localized })
        assertIcons(page)

        // WebKit's link section, iconed as WebKit does it.
        let link = NSMenu()
        for (title, identifier) in [("Open Link", "OpenLink"), ("Open Link in New Window", "OpenLinkInNewWindow"), ("Copy Link", "CopyLink")] {
            let item = link.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + identifier)
            item.image = MenuIcon.copyLink.image
        }
        builder.build(link, linkURL: URL(string: "https://example.com/a"), extensionItems: [])
        XCTAssertTrue(link.items.contains { $0.title == "Open Link in New Private Space".localized })
        assertIcons(link)

        let image = NSMenu()
        builder.build(image, linkURL: nil, imageURL: URL(string: "https://example.com/a.png"), extensionItems: [])
        XCTAssertTrue(image.items.contains { $0.title == "Download Image".localized })
        assertIcons(image)
    }

    func testTerminalMenu() throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 80, rows: 5, command: ["/bin/cat"])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        assertIcons(try XCTUnwrap(view.menu(for: event)))
    }
}
