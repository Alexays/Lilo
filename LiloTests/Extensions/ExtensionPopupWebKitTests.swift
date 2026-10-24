import XCTest
import WebKit
@testable import Lilo

@MainActor
final class ExtensionPopupWebKitTests: XCTestCase {

    private var delegate: ExtensionControllerDelegate?
    private var windowAdapter: WindowExtensionAdapter?

    override func setUp() {
        super.setUp()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
        windowAdapter = WindowExtensionAdapter(nsWindow: window)

        delegate = ExtensionControllerDelegate()
        delegate?.windowAdapter = windowAdapter
    }

    override func tearDown() {
        super.tearDown()
        delegate = nil
        windowAdapter = nil
    }

    private func makeExtensionContext() async throws -> WKWebExtensionContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let manifest = #"{"manifest_version":3,"name":"Delegate Test","version":"1.0","description":"Test"}"#
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        return WKWebExtensionContext(for: webExtension)
    }

    // MARK: - Tests

    /// Without space scoping (a floating-panel-style adapter), every added tab is exposed and the
    /// active tab resolves directly. Space-scoped exposure depends on the live TabManager/current
    /// space and is exercised by the app integration paths, not this lightweight unit.
    func testWindowAdapterExposesAllTabsWhenNotSpaceScoped() async throws {
        let context = try await makeExtensionContext()
        let firstEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let secondEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let firstAdapter = TabExtensionAdapter(engineTab: firstEngine, extensionWindow: windowAdapter)
        let secondAdapter = TabExtensionAdapter(engineTab: secondEngine, extensionWindow: windowAdapter)
        windowAdapter?.add(tab: firstAdapter)
        windowAdapter?.add(tab: secondAdapter)
        windowAdapter?.activeAdapter = secondAdapter

        XCTAssertFalse(windowAdapter?.scopesToCurrentSpace ?? true)
        XCTAssertEqual(windowAdapter?.tabs(for: context).count, 2)
        XCTAssertTrue(windowAdapter?.activeTab(for: context) as AnyObject === secondAdapter)
        XCTAssertTrue(secondAdapter.isSelected(for: context))
        XCTAssertFalse(firstAdapter.isSelected(for: context))
    }

    func testRemovingActiveTabClearsActiveAdapter() async throws {
        let context = try await makeExtensionContext()
        let adapter = TabExtensionAdapter(
            engineTab: WKWebViewTab(configuration: WKWebViewConfiguration()),
            extensionWindow: windowAdapter
        )
        windowAdapter?.add(tab: adapter)
        windowAdapter?.activeAdapter = adapter

        windowAdapter?.remove(tab: adapter)

        XCTAssertNil(windowAdapter?.activeAdapter)
        XCTAssertNil(windowAdapter?.activeTab(for: context))
        XCTAssertEqual(windowAdapter?.tabs(for: context).count, 0)
    }

    func testExtensionPopupURLsUseDetachedWebView() throws {
        let extensionURL = try XCTUnwrap(URL(string: "chrome-extension://extension-id/popup.html"))
        let websiteURL = try XCTUnwrap(URL(string: "https://example.com/popup"))

        XCTAssertTrue(MainWindowController.shouldCreateDetachedExtensionPopup(for: extensionURL))
        XCTAssertFalse(MainWindowController.shouldCreateDetachedExtensionPopup(for: websiteURL))
        XCTAssertFalse(MainWindowController.shouldCreateDetachedExtensionPopup(for: nil))
    }

    func testExtensionPopupWebViewDoesNotCreateBrowserTab() throws {
        let controller = MainWindowController()
        let extensionURL = try XCTUnwrap(URL(string: "chrome-extension://extension-id/popup.html"))

        let webView = controller.createPopupWebView(
            configuration: WKWebViewConfiguration(),
            requestedURL: extensionURL
        )

        XCTAssertNotNil(webView)
        XCTAssertEqual(controller.popupCloseHandlersByWebViewId.count, 1)
    }

    func testPermissionPromptFailsClosedWhenRegistryIsMissing() async throws {
        let delegate = try XCTUnwrap(delegate)
        let context = try await makeExtensionContext()
        let permission = WKWebExtension.Permission(rawValue: "tabs")

        var granted: Set<WKWebExtension.Permission>?
        delegate.webExtensionController(
            WKWebExtensionController(),
            promptForPermissions: [permission],
            in: nil,
            for: context
        ) { permissions, _ in
            granted = permissions
        }

        XCTAssertEqual(granted, [])
    }

    func testURLPermissionPromptFailsClosedWhenRegistryIsMissing() async throws {
        let delegate = try XCTUnwrap(delegate)
        let context = try await makeExtensionContext()
        let url = try XCTUnwrap(URL(string: "https://example.com/"))

        var granted: Set<URL>?
        delegate.webExtensionController(
            WKWebExtensionController(),
            promptForPermissionToAccess: [url],
            in: nil,
            for: context
        ) { urls, _ in
            granted = urls
        }

        XCTAssertEqual(granted, [])
    }
}
