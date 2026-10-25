import AppKit
import Foundation
@testable import Lilo

/// A bootstrapped BrowserContext on a unique temporary Application Support directory.
@MainActor
final class TemporaryBrowserContext {
    let context: BrowserContext
    private let directory: URL

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-context-\(UUID().uuidString)")
        context = BrowserContext(appSupportDirectory: directory.path, makeProfileId: TestProfileIds.next)
        try await context.bootstrap()
    }

    /// A window showing a space of a new profile, extensions set up, and that profile's registry.
    func makeExtensionWindow() throws -> (MainWindowController, ProfileExtensionRegistry) {
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let registry = try context.profileContexts.context(for: profileId).extensions
        let window = makeTestWindow(context, showing: space.id, size: NSSize(width: 1000, height: 800))
        window.setupExtensions()
        return (window, registry)
    }

    /// XCTest keeps every test case, and whatever it holds, until the run ends: a test keeping a window or a registry
    /// would keep their pages, popups and extension workers, each its own WebContent process. All end here instead.
    func tearDown() {
        for window in context.windows.windows { window.window?.close() }
        for tabId in context.browserState.allTabIds() { context.browserState.liveEngine(forTab: tabId)?.teardown() }
        for profile in context.profileContexts.allContexts { profile.extensions.teardown() }
        context.engineFactory.dropWarmPool()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A registered window of `context` showing `spaceId`, with its bridge and an unattached content view.
@MainActor
func makeTestWindow(_ context: BrowserContext, showing spaceId: UUID, size: NSSize = NSSize(width: 800, height: 600)) -> MainWindowController {
    let window = MainWindowController(context: context)
    window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
    window.contentContainerView = NSView(frame: NSRect(origin: .zero, size: size))
    context.windows.add(window)
    window.switchToSpace(spaceId)
    return window
}
