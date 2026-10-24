import AppKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeGlobalEventRoutingTests: XCTestCase {
    func testCmdLRemainsReservedToLilo() {
        let controller = MainWindowController()
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        )!

        XCTAssertTrue(controller.handleKeyboardShortcut(event))
    }

    func testReservedShortcutStaysWithLilo() {
        let controller = MainWindowController()
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        )!

        XCTAssertTrue(controller.handleKeyboardShortcut(event))
    }

    func testNonReservedKeyFallsThroughToActiveContent() {
        let controller = MainWindowController()
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeInput.router.updateContentView(sink)

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )!

        _ = controller.routeUnhandledGlobalEvent(event)

        XCTAssertEqual(sink.calls, [.keyDown("x")])
    }

    func testNonReservedKeyStaysLocalWhenChromeHasFocus() {
        let controller = MainWindowController()
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeInput.router.updateContentView(sink)
        controller.chromeWebView.frame = controller.window!.contentView!.bounds
        controller.window?.contentView?.addSubview(controller.chromeWebView)
        XCTAssertTrue(controller.window!.makeFirstResponder(controller.chromeWebView))
        XCTAssertTrue(controller.isFirstResponderInsideChromeUI())

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )!

        XCTAssertFalse(controller.routeUnhandledGlobalEvent(event))
        XCTAssertEqual(sink.calls, [])
    }

    func testEscapeUsesNativeDeliveryWhenContentHasFocus() {
        let controller = MainWindowController()
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeInput.router.updateContentView(sink)
        controller.window?.contentView?.addSubview(sink)
        XCTAssertTrue(controller.window!.makeFirstResponder(sink))

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!

        XCTAssertFalse(controller.handleKeyboardShortcut(event))
        XCTAssertFalse(controller.routeUnhandledGlobalEvent(event))
        XCTAssertEqual(sink.calls, [])
    }

    func testKeyStaysWithFocusedNonContentViewLikeExtensionPopup() {
        let controller = MainWindowController()
        let contentSink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        controller.chromeInput.router.updateContentView(contentSink)

        // An extension action popup hosted in this window's responder chain needs native delivery: the global fallback
        // would re-dispatch to the active tab and double-type every character.
        let popup = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.window?.contentView?.addSubview(popup)
        XCTAssertTrue(controller.window!.makeFirstResponder(popup))
        XCTAssertFalse(controller.isFirstResponderInsideChromeUI())
        XCTAssertFalse(controller.isFirstResponderInsideContentView())

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        XCTAssertFalse(controller.routeUnhandledGlobalEvent(event))
        XCTAssertEqual(contentSink.calls, [])
    }

    func testOpenHistoryMenuActionFocusesChromeBeforeOpeningCommandBar() {
        let controller = MainWindowController()
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        let sink = TestGlobalKeySinkView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        controller.chromeWebView.frame = controller.window!.contentView!.bounds
        controller.window?.contentView?.addSubview(controller.chromeWebView)
        controller.window?.contentView?.addSubview(sink)
        XCTAssertTrue(controller.window!.makeFirstResponder(sink))
        XCTAssertFalse(controller.isFirstResponderInsideChromeUI())

        controller.openHistory(nil)

        XCTAssertTrue(controller.isFirstResponderInsideChromeUI())
    }
}

@MainActor
private final class TestGlobalKeySinkView: NSView {
    enum Call: Equatable {
        case keyDown(String)
    }

    var calls: [Call] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        calls.append(.keyDown(event.charactersIgnoringModifiers ?? ""))
    }
}
