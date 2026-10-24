import AppKit
import XCTest
@testable import Lilo

@MainActor
final class TerminalTabTests: XCTestCase {
    func testTerminalTabSurvivesAStorageRoundTrip() throws {
        let tab = Tab(title: "Lilo", kind: .terminal, cwd: "/Users/me/Lilo", resumeCommand: "claude --continue")

        let data = try JSONEncoder().encode(StoredTab(tab))
        let restored = Tab(try JSONDecoder().decode(StoredTab.self, from: data), spaceId: UUID(), groupId: nil)

        XCTAssertEqual(restored.kind, .terminal)
        XCTAssertEqual(restored.cwd, "/Users/me/Lilo")
        XCTAssertEqual(restored.resumeCommand, "claude --continue")
    }

    func testTabsSavedBeforeTerminalsExistedDecodeAsWebTabs() throws {
        let savedBeforeTerminals = Data(#"{"id":"\#(UUID().uuidString)","url":"https://example.com","title":"Example","isPinned":false,"isBookmarked":false,"isClosed":false}"#.utf8)

        let stored = try JSONDecoder().decode(StoredTab.self, from: savedBeforeTerminals)

        XCTAssertEqual(stored.kind, .web)
        XCTAssertNil(stored.cwd)
    }

    func testWebTabsDoNotWriteAKindKey() throws {
        let json = String(decoding: try JSONEncoder().encode(StoredTab(Tab(url: URL(string: "https://example.com")))), as: UTF8.self)

        XCTAssertFalse(json.contains("\"kind\""))
    }

    func testRestoreKeepsTerminalTabsThatHaveNoURL() {
        let controller = MainWindowController()
        let terminal = Tab(title: "Lilo", kind: .terminal, cwd: "/tmp")
        let strayWebTab = Tab(title: "Something")

        let kept = controller.sanitizeTabs([terminal, strayWebTab], spaceId: UUID())

        XCTAssertEqual(kept.map(\.id), [terminal.id])
    }

    func testTitlePrefersTheProgramTitleThenCommandThenProcessAndFolder() {
        var status = TerminalSession.Status()
        status.cwd = "/Users/me/Lilo"
        status.foregroundProcess = "npm"
        XCTAssertEqual(MainWindowController.terminalTitle(for: status), "npm · Lilo")

        status.foregroundProcess = "zsh"
        XCTAssertEqual(MainWindowController.terminalTitle(for: status), "Lilo")

        status.state = .busy
        status.command = "npm run dev"
        XCTAssertEqual(MainWindowController.terminalTitle(for: status), "npm run dev")

        status.title = "vim README.md"
        XCTAssertEqual(MainWindowController.terminalTitle(for: status), "vim README.md")
    }

    func testActivatingATerminalTabCreatesNoWebEngine() throws {
        let spaceId = UUID()
        let terminal = Tab(title: "tmp", spaceId: spaceId, kind: .terminal, cwd: NSTemporaryDirectory())
        let state = try BrowserStateFixture(
            spaceId: spaceId, activeTabId: nil, tabs: [terminal], folders: [],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: terminal.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(state)), engines: [:])
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.browserStateStore = store
        tabManager.currentSpaceId = spaceId

        tabManager.activateTabRuntime(id: terminal.id)

        XCTAssertEqual(tabManager.activeTabId, terminal.id)
        XCTAssertNil(tabManager.engineTab(for: terminal.id))
        XCTAssertNil(tabManager.ensureLiveEngine(forTabId: terminal.id))
    }

    func testALinkedDocumentOpensInItsApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["notes.txt", "main.swift", "README.md", "shot.png", "paper.pdf"].map { directory.appendingPathComponent($0) }
        for file in files { try Data("x".utf8).write(to: file) }
        let host = TerminalHost()
        var opened: [URL] = []
        host.onOpenURL = { _, url in opened.append(url) }
        let tab = Tab(title: "a", kind: .terminal, cwd: NSTemporaryDirectory())
        let view = try XCTUnwrap(host.ensureView(for: tab))
        defer { host.terminate(tab.id) }

        for url in files + [directory] { view.onOpenURL?(url) }

        XCTAssertEqual(opened, files + [directory])
    }

    func testZoomOnlyChangesItsOwnTerminal() throws {
        let host = TerminalHost()
        let zoomed = Tab(title: "a", kind: .terminal, cwd: NSTemporaryDirectory())
        let other = Tab(title: "b", kind: .terminal, cwd: NSTemporaryDirectory())
        let view = try XCTUnwrap(host.ensureView(for: zoomed))
        let otherView = try XCTUnwrap(host.ensureView(for: other))
        defer { [zoomed, other].forEach { host.terminate($0.id) } }

        XCTAssertEqual(view.setZoom(by: 1), 14.0 / 13.0, accuracy: 0.001)
        XCTAssertEqual(view.setZoom(by: -100), 6.0 / 13.0, accuracy: 0.001, "a floor keeps text legible")
        XCTAssertEqual(otherView.zoom, 0)
        XCTAssertEqual(view.setZoom(by: nil), 1)
    }

    func testATerminalComesBackWithItsScreenAfterARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        let before = TerminalHost()
        before.snapshotDirectory = directory
        let view = try XCTUnwrap(before.ensureView(for: tab))
        Array("kept across a restart\r\n".utf8).withUnsafeBytes { bytes in view.session.withLockedTerminal { $0.write(bytes) } }

        // Quitting saves every terminal; the shells end with Lilo, the saved screens stay.
        before.saveSnapshots(visible: true)
        view.shutdown()
        view.session.terminate()
        let after = TerminalHost()
        after.snapshotDirectory = directory
        let restored = try XCTUnwrap(after.ensureView(for: tab))
        defer { after.terminate(tab.id) }

        let rows = restored.session.withLockedTerminal { terminal in (0..<terminal.rows).compactMap { terminal.line(row: $0)?.text } }
        XCTAssertTrue(rows.contains { $0.contains("kept across a restart") }, "\(rows)")
    }

    func testAPrefetchedTerminalComesBackWithItsScreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        let before = TerminalHost()
        before.snapshotDirectory = directory
        let view = try XCTUnwrap(before.ensureView(for: tab))
        Array("decoded ahead of its show\r\n".utf8).withUnsafeBytes { bytes in view.session.withLockedTerminal { $0.write(bytes) } }
        before.saveSnapshots(visible: true)
        view.shutdown()
        view.session.terminate()
        let after = TerminalHost()
        after.snapshotDirectory = directory

        after.prefetchRestore(of: tab.id)
        let restored = try XCTUnwrap(after.ensureView(for: tab))
        defer { after.terminate(tab.id) }

        let rows = restored.session.withLockedTerminal { terminal in (0..<terminal.rows).compactMap { terminal.line(row: $0)?.text } }
        XCTAssertTrue(rows.contains { $0.contains("decoded ahead of its show") }, "\(rows)")
    }

    func testAReopenedTerminalComesBackWithTheScreenItsClosedTabKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TerminalHost()
        host.snapshotDirectory = directory
        let closed = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        let view = try XCTUnwrap(host.ensureView(for: closed))
        Array("kept for a reopen\r\n".utf8).withUnsafeBytes { bytes in view.session.withLockedTerminal { $0.write(bytes) } }

        XCTAssertTrue(host.keepScreen(of: closed.id))
        host.forget(closed.id)
        let reopened = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        host.adoptScreen(of: closed.id, for: reopened.id)
        let restored = try XCTUnwrap(host.ensureView(for: reopened))
        defer { host.terminate(reopened.id) }

        let rows = restored.session.withLockedTerminal { terminal in (0..<terminal.rows).compactMap { terminal.line(row: $0)?.text } }
        XCTAssertTrue(rows.contains { $0.contains("kept for a reopen") }, "\(rows)")
    }

    func testAHiddenTerminalIsSavedOnlyOnceItsOutputHeldStillForAWholePass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TerminalHost()
        host.snapshotDirectory = directory
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        // tr in the foreground prints only what it is sent, and the shell stays quiet until it ends: output moves on cue.
        host.setInitialCommand("/usr/bin/env -i /usr/bin/tr a-z A-Z", for: tab.id)
        let session = try XCTUnwrap(host.ensureView(for: tab)).session
        defer { host.terminate(tab.id) }
        let snapshot = directory.appendingPathComponent(tab.id.uuidString + ".snapshot")
        let trRuns = await pollUntil(timeout: 20) { session.foregroundProgram() == "tr" }
        XCTAssertTrue(trRuns, "\(session.status)")
        // tr's reply comes after the tty echo, which a user's prompt redraw can repeat on screen while tr
        // starts: the reply shown and the count steady, all of it is counted.
        func echo(_ marker: String) async -> Bool {
            session.write(Array((marker + "\n").utf8))
            var counted = -1
            return await pollUntil(timeout: 20) {
                let shown = session.withLockedTerminal { terminal in (0..<terminal.rows).contains { terminal.line(row: $0)?.text.contains(marker.uppercased()) == true } }
                let batches = session.outputBatches
                defer { counted = batches }
                return shown && batches == counted
            }
        }

        let firstShown = await echo("lilo-first")
        XCTAssertTrue(firstShown)
        XCTAssertTrue(host.saveSnapshots(visible: false), "a first pass notes the output and waits")
        let secondShown = await echo("lilo-second")
        XCTAssertTrue(secondShown)
        XCTAssertTrue(host.saveSnapshots(visible: false), "output moved since the last pass: still waiting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))

        XCTAssertTrue(host.saveSnapshots(visible: false))
        let saved = await pollUntil(timeout: 20) { FileManager.default.fileExists(atPath: snapshot.path) }
        XCTAssertTrue(saved, "output unchanged for a whole pass is saved")
        XCTAssertFalse(host.saveSnapshots(visible: false), "nothing new since the save")
    }

    func testAClosedTerminalLeavesNoScreenBehindASaveStillQueued() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TerminalHost()
        host.snapshotDirectory = directory
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        host.setInitialCommand("/usr/bin/env -i /bin/cat", for: tab.id)
        let session = try XCTUnwrap(host.ensureView(for: tab)).session
        let catRuns = await pollUntil(timeout: 20) { session.foregroundProgram() == "cat" }
        XCTAssertTrue(catRuns, "\(session.status)")
        var counted = -1
        let steady = await pollUntil(timeout: 20) {
            let batches = session.outputBatches
            defer { counted = batches }
            return batches == counted
        }
        XCTAssertTrue(steady)

        // A first pass notes the output, the second queues its save.
        host.saveSnapshots(visible: false)
        host.saveSnapshots(visible: false)
        host.forget(tab.id)
        // A quit's save waits for the queued ones.
        host.saveSnapshots(visible: true)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testAPrivateTerminalKeepsNoScreenWhenClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TerminalHost()
        host.snapshotDirectory = directory
        host.savesSnapshot = { _ in false }
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        _ = try XCTUnwrap(host.ensureView(for: tab))
        defer { host.terminate(tab.id) }

        XCTAssertFalse(host.keepScreen(of: tab.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testHostStartsAShellOnFirstUseAndEndsItWhenTheTabGoes() async throws {
        let host = TerminalHost()
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())

        let view = try XCTUnwrap(host.ensureView(for: tab))
        XCTAssertTrue(host.ensureView(for: tab) === view, "One shell per tab")
        XCTAssertGreaterThan(view.session.pid, 0)

        host.prune { _ in false }

        XCTAssertNil(host.view(for: tab.id))
        // A login shell under a loaded machine (the whole suite in parallel) can take seconds to go.
        await pollUntil(timeout: 20) { view.session.status.state == .exited }
        XCTAssertEqual(view.session.status.state, .exited)
    }

    func testAQuitEndsAShellStillStarting() async throws {
        let host = TerminalHost()
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        let view = try XCTUnwrap(host.ensureView(for: tab))
        defer { host.terminate(tab.id) }

        host.terminateAllForQuit()

        await pollUntil(timeout: 20) { view.session.status.state == .exited }
        XCTAssertEqual(view.session.status.state, .exited)
        XCTAssertEqual(kill(-view.session.pid, 0), -1, "nothing of the login group outlives the quit")
    }

    func testAQuitEndsADetachedDescendantOfAShell() async throws {
        let host = TerminalHost()
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        let view = try XCTUnwrap(host.ensureView(for: tab))
        defer { host.terminate(tab.id) }
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-detached-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // A child in its own session, as a prompt worker or an agent's command: no hangup reaches it.
        let command = "perl -MPOSIX -e 'if (my $c = fork) { waitpid $c, 0; exit } POSIX::setsid(); open my $f, \">\", shift; print $f $$; close $f; sleep 60' '\(pidFile.path)' &\n"
        view.session.write(Array(command.utf8))
        await pollUntil(timeout: 20) { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init) != nil }
        let detached = try XCTUnwrap((try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init))

        host.terminateAllForQuit()

        await pollUntil(timeout: 5) { kill(detached, 0) != 0 }
        XCTAssertNotEqual(kill(detached, 0), 0, "a detached descendant does not outlive the quit")
    }

    func testAClosedTerminalReleasesItsSessionAndRenderThread() async throws {
        let host = TerminalHost()
        let tab = Tab(title: "tmp", kind: .terminal, cwd: NSTemporaryDirectory())
        weak var session: TerminalSession?
        weak var renderLoop: TerminalRenderLoop?
        do {
            let view = try XCTUnwrap(host.ensureView(for: tab))
            session = view.session
            renderLoop = view.renderLoop
        }

        host.terminate(tab.id)

        await pollUntil(timeout: 20) { session == nil && renderLoop == nil }
        XCTAssertNil(renderLoop)
        XCTAssertNil(session)
    }
}

@MainActor
final class TerminalReopenTests: XCTestCase {
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

    func testReopeningAClosedTerminalOpensANewOneInItsFolder() throws {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let window = makeTestWindow(context, showing: space.id)
        window.createTabStateFirst(url: URL(string: "https://example.com"))
        let terminal = try XCTUnwrap(window.createTerminalTab(activate: false, cwd: "/tmp", resumeCommand: "claude"))

        window.closeTabStateFirst(id: terminal.id)
        let reopened = try XCTUnwrap(window.restoreClosedTabStateFirst())

        XCTAssertEqual(reopened.kind, .terminal)
        XCTAssertEqual(reopened.cwd, "/tmp")
        XCTAssertEqual(reopened.resumeCommand, "claude", "its last program is typed at the new prompt")
        XCTAssertNotEqual(reopened.id, terminal.id, "a new shell, not the closed one")
        XCTAssertFalse(window.isVisibleToExtensions(RecentlyClosedStack.Entry(
            content: .terminal(.init(cwd: "/tmp")), spaceId: space.id, parentFolderId: nil, section: nil, sortOrder: nil
        )), "extensions never see closed terminals")
    }

    func testTheCommandBarReopensAClosedTerminalByItsPlaceInTheList() throws {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let window = makeTestWindow(context, showing: space.id)
        window.createTabStateFirst(url: URL(string: "https://example.com"))
        let older = try XCTUnwrap(window.createTerminalTab(activate: false, cwd: "/tmp"))
        let newer = try XCTUnwrap(window.createTerminalTab(activate: false, cwd: "/usr"))
        window.closeTabStateFirst(id: older.id)
        let page = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.org")))
        window.closeTabStateFirst(id: newer.id)
        window.closeTabStateFirst(id: page.id)

        XCTAssertEqual(window.closedTerminalSummaries().compactMap { $0["folder"] as? String }, ["usr", "tmp"], "newest first, pages left out")
        let reopened = try XCTUnwrap(window.restoreClosedTerminal(at: 1))

        XCTAssertEqual(reopened.cwd, "/tmp")
        XCTAssertEqual(window.closedTerminalSummaries().compactMap { $0["folder"] as? String }, ["usr"])
    }

    func testClosedTerminalsOutliveTheLaunchForThirtyDays() async throws {
        let context = browserContext.context
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-closed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        context.terminalHost.snapshotDirectory = directory
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let entry = { (cwd: String, closedAt: Date) in
            RecentlyClosedStack.Entry(
                content: .terminal(.init(cwd: cwd, closedAt: closedAt)), spaceId: space.id, parentFolderId: nil, section: nil, sortOrder: nil
            )
        }
        let saved = [entry("/old", Date().addingTimeInterval(-31 * 24 * 3600)), entry("/recent", Date())]
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("closed.json"))

        context.restoreClosedTerminals()

        let restored = context.recentlyClosed.recentEntries.compactMap { entry -> String? in
            guard case .terminal(let closed) = entry.content else { return nil }
            return closed.cwd
        }
        XCTAssertEqual(restored, ["/recent"])
        let file = directory.appendingPathComponent("closed.json")
        let onDisk = { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([RecentlyClosedStack.Entry].self, from: $0) } }
        let rewritten = await pollUntil(timeout: 5) { onDisk()?.count == 1 }
        XCTAssertTrue(rewritten, "the list on disk follows the stack")

        try FileManager.default.removeItem(at: file)
        context.recentlyClosed.push(.page(URL(string: "https://example.com")!), spaceId: space.id, parentFolderId: nil, section: nil, sortOrder: nil)
        let rewrittenForAPage = await pollUntil(timeout: 1) { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertFalse(rewrittenForAPage, "a closed page leaves the saved terminals alone")

        for cwd in ["/a", "/b", "/c"] {
            context.recentlyClosed.push(.terminal(.init(cwd: cwd)), spaceId: space.id, parentFolderId: nil, section: nil, sortOrder: nil)
        }
        let savedAll = await pollUntil(timeout: 5) { onDisk()?.count == 4 }
        XCTAssertTrue(savedAll, "terminals closed in one turn all reach the disk")
    }
}
