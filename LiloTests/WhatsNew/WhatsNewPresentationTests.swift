import AppKit
import XCTest
@testable import Lilo

@MainActor
final class WhatsNewPresentationTests: XCTestCase {
    func testTheMountedDialogOwnsAndRestoresNativeFocus() async throws {
        let fixture = try await TemporaryBrowserContext()
        defer { fixture.tearDown() }
        let controller = MainWindowController(context: fixture.context)
        fixture.context.windows.add(controller)
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let content = NSView(frame: root.bounds)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        content.addSubview(field)
        root.addSubview(content)
        controller.chromeWebView.frame = root.bounds
        root.addSubview(controller.chromeWebView)
        controller.contentContainerView = content
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        controller.bridgeRouter.javaScriptSink = { _, _, completion in completion() }
        XCTAssertTrue(window.makeFirstResponder(field))
        // The host has dispatched a request; the JS mount acknowledgment reaches the real native views.
        controller.whatsNewRequested = true

        let key = "whatsNewHighestPresentedVersion"
        let previousMarker = UserDefaults.lilo.object(forKey: key)
        defer { UserDefaults.lilo.set(previousMarker, forKey: key) }
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        controller.acknowledgeWhatsNew(version: version)
        XCTAssertTrue(controller.isShowingWhatsNew)
        XCTAssertTrue(content.isAccessibilityHidden())
        XCTAssertTrue(controller.contains(responder: window.firstResponder))
        XCTAssertFalse(window.makeFirstResponder(field), "a page cannot steal focus from the dialog")

        controller.dismissWhatsNew()
        XCTAssertFalse(controller.isShowingWhatsNew)
        XCTAssertFalse(content.isAccessibilityHidden())
        XCTAssertTrue(window.firstResponder === field)
    }
}
