import AppKit
import XCTest
@testable import Lilo

@MainActor
final class SessionRestorePreloadTests: XCTestCase {

    private func snapshot(
        spaces: [Space],
        lastActiveProfileId: UUID?,
        storedSpaceIdsByProfile: [UUID: [String: UUID]] = [:]
    ) -> BrowserContext.StartupSnapshot {
        BrowserContext.StartupSnapshot(
            profiles: [],
            spaces: spaces,
            lastActiveProfileId: lastActiveProfileId,
            storedSpaceIdsByProfile: storedSpaceIdsByProfile,
            windowBackgroundColor: nil
        )
    }

    private func storedTab(id: UUID, url: String, title: String) -> StoredTab {
        StoredTab(
            id: id, url: url, title: title,
            faviconDataURL: nil, faviconDominantColor: nil,
            isPinned: false, isBookmarked: false, isClosed: false,
            homeURL: nil, homeTitle: nil,
            homeFaviconDataURL: nil, homeFaviconDominantColor: nil
        )
    }

    func testStartupNonCriticalUICoordinatorDefersUntilNavigationStarts() {
        let coordinator = MainWindowController.StartupNonCriticalUICoordinator()
        var didRun = false

        coordinator.enqueue { didRun = true }
        XCTAssertFalse(didRun)

        coordinator.markNavigationStarted()
        XCTAssertTrue(didRun)
    }

    func testStartupNonCriticalUICoordinatorRunsImmediatelyAfterNavigationStarts() {
        let coordinator = MainWindowController.StartupNonCriticalUICoordinator()
        coordinator.markNavigationStarted()

        var didRun = false
        coordinator.enqueue { didRun = true }
        XCTAssertTrue(didRun)
    }

    // MARK: - predictedInitialSpace (pure mirror of resolveInitialSpace)

    func testPredictedInitialSpacePrefersLastActiveSpace() {
        let profileId = UUID()
        let a = Space(name: "A", profileId: profileId)
        let b = Space(name: "B", profileId: profileId)
        let s = snapshot(
            spaces: [a, b],
            lastActiveProfileId: profileId,
            storedSpaceIdsByProfile: [profileId: ["lastActiveSpaceId": b.id]]
        )

        XCTAssertEqual(MainWindowController.predictedInitialSpace(from: s)?.id, b.id)
    }

    func testPredictedInitialSpaceFallsBackToNonPrivatePersistentSpace() {
        let profileId = UUID()
        let a = Space(name: "A", profileId: profileId)
        let b = Space(name: "B", profileId: profileId)
        // lastActiveSpaceId points at a space that no longer exists.
        let s = snapshot(
            spaces: [a, b],
            lastActiveProfileId: profileId,
            storedSpaceIdsByProfile: [profileId: [
                "lastActiveSpaceId": UUID(),
                "lastPersistentSpaceId": b.id
            ]]
        )

        XCTAssertEqual(MainWindowController.predictedInitialSpace(from: s)?.id, b.id)
    }

    func testPredictedInitialSpaceFallsBackToFirstProfileSpace() {
        let profileId = UUID()
        let other = Space(name: "Other", profileId: UUID())
        let mine = Space(name: "Mine", profileId: profileId)
        let s = snapshot(spaces: [other, mine], lastActiveProfileId: profileId)

        XCTAssertEqual(MainWindowController.predictedInitialSpace(from: s)?.id, mine.id)
    }

    func testPredictedInitialSpaceIsNilWithoutSpaces() {
        XCTAssertNil(MainWindowController.predictedInitialSpace(
            from: snapshot(spaces: [], lastActiveProfileId: UUID())
        ))
    }

    // MARK: - One-shot consumption

    func testRestoredSpaceSnapshotConsumesMatchingPreload() {
        let controller = MainWindowController()
        let space = Space(name: "S", profileId: UUID())
        let tabId = UUID()
        let tabState = SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(storedTab(id: tabId, url: "https://example.com", title: "Example"))],
                bookmarked: []
            )
        )
        controller.preloadedSpaceRestoreState = MainWindowController.PreloadedSpaceRestoreState(
            profileId: space.profileId,
            spaceId: space.id,
            tabState: tabState,
            interactionStates: [:]
        )

        let restored = controller.restoredSpaceSnapshot(for: space)

        XCTAssertEqual(restored.spaceTab.state.activeTabId, tabId)
        XCTAssertNil(controller.preloadedSpaceRestoreState, "the preload must be one-shot")
    }

    func testPreloadIsClearedEvenWhenTheSpaceDoesNotMatch() {
        let controller = MainWindowController()
        controller.preloadedSpaceRestoreState = MainWindowController.PreloadedSpaceRestoreState(
            profileId: UUID(),
            spaceId: UUID(),
            tabState: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty),
            interactionStates: [:]
        )

        let unrelated = Space(name: "Unrelated", profileId: UUID())
        XCTAssertNil(controller.takePreloadedSpaceRestoreState(matching: unrelated))
        XCTAssertNil(controller.preloadedSpaceRestoreState,
                     "a stale boot preload must never survive past the first restore attempt")
    }

    // MARK: - Hidden spaces and interaction states, through a bootstrapped context

    private func makeWindow(_ browserContext: TemporaryBrowserContext) -> MainWindowController {
        let window = MainWindowController(context: browserContext.context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        window.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        return window
    }

    func testFinishedRestorePreloadsHiddenSpacesIntoTheSnapshotCache() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let shown = try context.spaceManager.createSpace(name: "Shown", profileId: profileId)
        let hidden = try context.spaceManager.createSpace(name: "Hidden", profileId: profileId)
        let tabId = UUID()
        let pool = try context.dbManager.pool(for: profileId)
        try SpaceTabStateStore(dbPool: pool).saveMany([(spaceId: hidden.id, state: SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(storedTab(id: tabId, url: "https://hidden.example/", title: "Hidden"))],
                bookmarked: []
            )
        ))])
        let window = makeWindow(browserContext)
        window.switchToSpace(shown.id)
        XCTAssertNil(context.browserState.space(id: hidden.id))

        window.finishSessionRestore()

        // The preload waits 3 s, then reads at background priority, which a busy machine starves for seconds more.
        await pollUntil(timeout: 30) { context.browserState.space(id: hidden.id) != nil }
        let snapshot = try XCTUnwrap(context.browserState.space(id: hidden.id), "the hidden space is preloaded once launch settles")
        XCTAssertEqual(snapshot.spaceTab.tab(id: tabId)?.url?.absoluteString, "https://hidden.example/")
        XCTAssertEqual(snapshot.spaceTab.state.activeTabId, tabId)
    }

    func testTheLaunchSweepDropsOnlyTheStateOfSpacesThatAreGone() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let kept = try context.spaceManager.createSpace(name: "Kept", profileId: profileId)
        let gone = UUID()
        let pool = try context.dbManager.pool(for: profileId)
        let store = SpaceTabStateStore(dbPool: pool)
        let empty = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
        try store.saveMany([(spaceId: kept.id, state: empty), (spaceId: gone, state: empty)])
        let window = makeWindow(browserContext)

        window.deleteOrphanedSpaceStates()

        let swept = await pollUntil(timeout: 5) { (try? store.load(spaceId: gone)) == nil }
        XCTAssertTrue(swept)
        XCTAssertNotNil(try store.load(spaceId: kept.id))
    }

    func testSpaceSwitchHoldsInteractionStatesUntilTheAppResignsActive() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let left = try context.spaceManager.createSpace(name: "Left", profileId: profileId)
        let next = try context.spaceManager.createSpace(name: "Next", profileId: profileId)
        let pool = try context.dbManager.pool(for: profileId)
        let store = InteractionStateStore(dbPool: pool)
        let window = makeWindow(browserContext)
        window.switchToSpace(left.id)
        let stashedTabId = UUID()
        window.tabManager.engineHost.saveInteractionState("stashed-state" as NSString, for: stashedTabId)

        window.switchToSpace(next.id)
        // The writer queue is serial, so this empty write lands after any write the switch queued.
        try await pool.write { _ in }
        XCTAssertNil(try store.load(spaceId: left.id)[stashedTabId], "a space switch holds its capture in memory")

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        await pollUntil {
            _ = try? await pool.write { _ in }
            return (try? store.load(spaceId: left.id)[stashedTabId]) != nil
        }

        let data = try XCTUnwrap(try store.load(spaceId: left.id)[stashedTabId], "resigning active writes the held capture")
        XCTAssertEqual(InteractionStateCodec.decode(data) as? String, "stashed-state")
    }

    func testRestoreAfterAnUncleanShutdownReportsTheCrashRecovery() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        _ = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        context.settingsStore.sessionCleanShutdown = false
        let window = makeWindow(browserContext)
        let recorder = BridgeEventRecorder(window.bridgeRouter)

        await window.restoreSession()

        XCTAssertNotNil(window.tabManager.currentSpaceId, "the restore succeeds")
        // The bridge ships at the end of the main-queue turn, which an async test reaches only by suspending.
        let reported = await pollUntil { recorder.events.contains { $0.name == "crashRecoveryDetected" } }
        XCTAssertTrue(reported)
    }

    func testAClosedPinnedTerminalKeepsNoScreen() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = makeWindow(browserContext)
        window.switchToSpace(space.id)
        let host = window.tabManager.terminalHost
        host.snapshotDirectory = directory
        let terminal = try XCTUnwrap(window.createTerminalTab(activate: false, cwd: "/tmp"))
        _ = try XCTUnwrap(host.ensureView(for: terminal))
        try window.applyBrowserCommand(.setPinned(spaceId: space.id, tabId: terminal.id, isPinned: true))

        XCTAssertFalse(window.recordClosedTabForRestore(id: terminal.id))
        host.forget(terminal.id)
        // A quit's save waits for the queued ones.
        host.saveSnapshots(visible: true)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
