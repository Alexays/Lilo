import AppKit
import XCTest
@testable import Lilo

@MainActor
final class WindowChromeColorTests: XCTestCase {
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

    private func launchedController() -> MainWindowController {
        let controller = MainWindowController(context: browserContext.context)
        // Startup is skipped under XCTest: its first sidebar step runs by hand.
        controller.contentContainerView = NSView()
        controller.window?.contentView?.addSubview(controller.contentContainerView)
        controller.restoreWindowChromeState()
        return controller
    }

    /// Expected values are `--sidebar-bg` from deriveSidebarThemeVariables in lilo-ui/src/lib/sidebarTheme.ts.
    func testTheFrameColorMatchesThePageSidebarForEverySpaceColor() {
        let expected: [(space: String, light: String, dark: String)] = [
            ("#000000", "#b4b2b8", "#191b23"),
            ("#20242e", "#bdbcc4", "#262a36"),
            ("#ffffff", "#fbf9ff", "#2b2b2b"),
            ("#fff4cc", "#fbf6f1", "#352c08"),
            ("#e2daf1", "#f3effb", "#362f41"),
            ("#44dd77", "#c7f0d9", "#08451f"),
            ("#aaee11", "#e4f4bc", "#213c00"),
            ("#ff0000", "#fbb2b8", "#841b23"),
            ("#0040ff", "#b4c4ff", "#19368e"),
            ("#4a90d9", "#c9daf4", "#204265"),
            ("#ff00ff", "#fbb2ff", "#820e82"),
            ("#f0a8c8", "#f7e1f0", "#552f41"),
            ("#c3a5ea", "#ebe0f9", "#453657"),
            ("#f4bb8c", "#f8e6df", "#4f3115"),
            ("#9bd3b4", "#dfedea", "#133f2a"),
            ("#8fd5cf", "#dcedf2", "#00403d"),
        ]
        for (space, light, dark) in expected {
            let color = NSColor(cssHex: space)!
            XCTAssertEqual(color.sidebarBackgroundColor(prefersDark: false).cssHexString, light, "\(space) light")
            XCTAssertEqual(color.sidebarBackgroundColor(prefersDark: true).cssHexString, dark, "\(space) dark")
        }
    }

    func testANewColorReachesEveryPaneOfTheSplit() throws {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        window.contentContainerView.wantsLayer = true
        window.didCompleteSessionRestore = true
        let first = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let second = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"), activate: false))
        window.splitTab(second.id, at: first.id, vertical: false, before: false)
        XCTAssertEqual(window.displayedTabIds, [first.id, second.id])

        window.applyWindowChromeColors("#841b23")
        // Its persistence would land in the next test's first-frame cache.
        window.pendingWindowBackgroundPersistWork?.cancel()

        let colors = try [first.id, second.id].map { try XCTUnwrap(window.tabManager.engineTab(for: $0)).wkWebView.underPageBackgroundColor }
        XCTAssertEqual(colors[0], colors[1], "the pane out of focus shows the new color under its page too")
    }

    func testTheFirstFrameAfterAnAppearanceSwitchKeepsTheNewAppearance() async throws {
        let keys = ["cachedWindowBgColor", "cachedWindowBgColor.light", "cachedWindowBgColor.dark"]
        let saved = keys.map { UserDefaults.lilo.object(forKey: $0) }
        let savedAppearance = NSApp.appearance
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.lilo.set(value, forKey: key) }
            NSApp.appearance = savedAppearance
        }
        keys.forEach(UserDefaults.lilo.removeObject(forKey:))

        NSApp.appearance = NSAppearance(named: .aqua)
        let lightColor = "#d8e4f0"
        let lightLaunch = launchedController()
        lightLaunch.applyWindowChromeColors(lightColor)
        // The color persists once it settles, half a second later.
        await pollUntil { UserDefaults.lilo.string(forKey: "cachedWindowBgColor.light") == lightColor }
        lightLaunch.window?.close()

        // macOS switched to dark while Lilo was closed.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let relaunched = launchedController()

        XCTAssertNotEqual(relaunched.window?.backgroundColor.cssHexString, lightColor, "a light sidebar color in dark mode")
        XCTAssertEqual(relaunched.window?.backgroundColor.cssHexString, MainWindowController.defaultSidebarBackgroundColor().cssHexString)
        relaunched.window?.close()

        NSApp.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(launchedController().window?.backgroundColor.cssHexString, lightColor, "back in light mode, the light color is still cached")
    }

    /// The database keeps the last color of either appearance: a first launch in the other one keeps its default.
    func testTheDatabaseColorOfTheOtherAppearanceNeverPaintsALaunch() async throws {
        let keys = ["cachedWindowBgColor", "cachedWindowBgColor.light", "cachedWindowBgColor.dark"]
        let saved = keys.map { UserDefaults.lilo.object(forKey: $0) }
        let savedAppearance = NSApp.appearance
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.lilo.set(value, forKey: key) }
            NSApp.appearance = savedAppearance
        }
        keys.forEach(UserDefaults.lilo.removeObject(forKey:))
        browserContext.context.settingsStore.windowBackgroundColor = "#d8e4f0"

        // Lilo was only ever used in light mode; macOS is dark now.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let relaunch = BrowserContext(appSupportDirectory: browserContext.context.appSupportDirectory, makeProfileId: { TestProfileIds.next() })
        try await relaunch.bootstrap()
        let controller = MainWindowController(context: relaunch)
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        controller.contentContainerView = NSView()
        controller.contentContainerView.wantsLayer = true
        controller.window?.contentView?.addSubview(controller.contentContainerView)
        controller.restoreWindowChromeState()
        await controller.setupDatabase()
        controller.reconcileBootstrapCacheWithDB()

        let dark = MainWindowController.defaultSidebarBackgroundColor()
        XCTAssertEqual(controller.window?.backgroundColor.cssHexString, dark.cssHexString)
        XCTAssertEqual(controller.currentContentSurfaceColor.cssHexString, dark.contentSurfaceColor.cssHexString, "under the first page")
        XCTAssertNil(UserDefaults.lilo.string(forKey: "cachedWindowBgColor.dark"))
    }
}
