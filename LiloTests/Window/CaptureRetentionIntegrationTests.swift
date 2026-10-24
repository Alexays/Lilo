import WebKit
import XCTest
@testable import Lilo

@MainActor
final class CaptureRetentionIntegrationTests: XCTestCase {
    // The on-to-off edge must come from the overlay-applied tab (the durable tab's capture flags are always false), so
    // `lastCaptureStoppedAt` arms the grace that keeps an in-call engine alive through WebKit's transient `.none` blips.
    func testCaptureStopStampsRetentionGraceThroughDelegate() throws {
        let wc = MainWindowController()
        let spaceId = UUID()
        let tabId = UUID()
        let fixture = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabId,
            tabs: [Tab(id: tabId, url: URL(string: "https://meet.example"), title: "Call", spaceId: spaceId)],
            folders: [],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )
        // Store as a NON-current (hidden) space so isVisibleTab() is false and updateAndEmit short-circuits
        // before the (test-absent) bridge: the delegate then runs purely through browserStateStore.updateTab,
        // the background-tab path where reading the bare durable tab would lose the capture flags.
        wc.context.browserState.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(fixture)),
                engines: [:]
            )
        )
        // The delegate only reads `.id` off the engine tab; the WKWebView is an inert vehicle for it.
        let engineTab = WKWebViewTab(id: tabId, configuration: WKWebViewConfiguration())

        func overlayTab() -> Tab { wc.context.browserState.runtimeOverlay.applied(to: Tab(id: tabId)) }

        // Capture starts (mic + screen): flags set, grace cleared.
        wc.tab(engineTab, didUpdatePermissionUsage: .init(usesMicrophone: true, usesScreen: true))
        XCTAssertTrue(overlayTab().isMicrophoneActive)
        XCTAssertTrue(overlayTab().isScreenSharing)
        XCTAssertNil(overlayTab().lastCaptureStoppedAt, "grace must be cleared while capturing")

        // Capture stops (WebKit reports `.none`): the on-to-off edge must stamp the retention grace so the
        // engine survives long enough to absorb a transient blip instead of being trimmed immediately.
        wc.tab(engineTab, didUpdatePermissionUsage: .none)
        XCTAssertFalse(overlayTab().isMicrophoneActive)
        XCTAssertFalse(overlayTab().isScreenSharing)
        XCTAssertNotNil(overlayTab().lastCaptureStoppedAt, "on-to-off capture edge must arm the retention grace")
    }
}
