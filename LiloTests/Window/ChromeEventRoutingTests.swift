import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeEventRoutingTests: XCTestCase {
    // MARK: - Classification

    /// A router over a 200pt chrome with one zone at the viewport's top-left 50pt square: window
    /// (20, 180) maps to viewport (20, 20), inside it, and (150, 150) lands outside.
    private func makeRouter(content: Bool = true) -> (router: ChromeEventRouter, chrome: OverlayWebView, content: NSView) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        let chrome = OverlayWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let router = ChromeEventRouter(zoneStore: ChromeInteractiveZoneStore(), captureMachine: ChromeCaptureMachine())
        chrome.eventRouter = router
        // The router holds the content view weakly: the caller keeps it alive.
        let contentView = NSView(frame: chrome.bounds)
        if content { router.updateContentView(contentView) }
        router.zoneStore.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 50))])
        return (router, chrome, contentView)
    }

    func testPointInsideInteractiveZoneClassifiesAsChrome() {
        let harness = makeRouter()
        XCTAssertEqual(harness.router.target(forWindowPoint: NSPoint(x: 20, y: 180)), .chrome)
    }

    func testPointOutsideAllZonesWithContentClassifiesAsContent() {
        let harness = makeRouter()
        XCTAssertEqual(harness.router.target(forWindowPoint: NSPoint(x: 150, y: 150)), .content)
    }

    func testPointOutsideAllZonesWithoutContentClassifiesAsNone() {
        XCTAssertEqual(makeRouter(content: false).router.target(forWindowPoint: NSPoint(x: 150, y: 150)), .none)
    }

    func testContentViewIdenticalToChromeIsTreatedAsNoContent() {
        let (router, chrome, _) = makeRouter(content: false)
        router.updateContentView(chrome)
        XCTAssertEqual(router.target(forWindowPoint: NSPoint(x: 150, y: 150)), .none)
    }

    func testMultipleZonesAreAllConsidered() {
        let harness = makeRouter()
        harness.router.zoneStore.registerZones([(id: "b", rect: NSRect(x: 100, y: 100, width: 20, height: 20))])
        // Window (110, 90) maps to viewport (110, 110): inside zone "b"; (60, 140) to (60, 60): inside neither.
        XCTAssertEqual(harness.router.target(forWindowPoint: NSPoint(x: 110, y: 90)), .chrome)
        XCTAssertEqual(harness.router.target(forWindowPoint: NSPoint(x: 60, y: 140)), .content)
    }

    // MARK: - Shield, through the window controller

    func testShieldAndOverlayHitTestsAgreeWithRouter() {
        let harness = makeHarness()
        // Each view hit-tests in its superview's coordinates: the shield sits in the chrome web view.
        let host = harness.controller.window!.contentView!
        let chrome = harness.controller.chromeWebView
        XCTAssertNotNil(harness.shield.hitTest(chrome.convert(harness.chromePoint, from: nil)))
        XCTAssertNotNil(chrome.hitTest(host.convert(harness.chromePoint, from: nil)))
        XCTAssertNil(harness.shield.hitTest(chrome.convert(harness.contentPoint, from: nil)))
        XCTAssertNil(chrome.hitTest(host.convert(harness.contentPoint, from: nil)))
    }

    func testShieldRoutesRightMouseDownOutsideInteractiveZonesToContent() {
        let harness = makeHarness()
        harness.shield.rightMouseDown(with: harness.mouseEvent(.rightMouseDown, at: harness.contentPoint))
        XCTAssertEqual(harness.content.calls, [.rightMouseDown])
    }

    func testShieldKeepsChromeOwnedMouseSequenceWhenPointerLeavesInteractiveZone() {
        let harness = makeHarness()
        harness.shield.rightMouseDown(with: harness.mouseEvent(.rightMouseDown, at: harness.chromePoint))
        harness.shield.rightMouseDragged(with: harness.mouseEvent(.rightMouseDragged, at: harness.contentPoint))
        harness.shield.rightMouseUp(with: harness.mouseEvent(.rightMouseUp, at: harness.contentPoint))
        XCTAssertEqual(harness.content.calls, [])
    }

    func testShieldKeepsContentOwnedMouseSequenceWhenPointerEntersInteractiveZone() {
        let harness = makeHarness()
        harness.shield.rightMouseDown(with: harness.mouseEvent(.rightMouseDown, at: harness.contentPoint))
        harness.shield.rightMouseDragged(with: harness.mouseEvent(.rightMouseDragged, at: harness.chromePoint))
        harness.shield.rightMouseUp(with: harness.mouseEvent(.rightMouseUp, at: harness.chromePoint))
        XCTAssertEqual(harness.content.calls, [.rightMouseDown, .rightMouseDragged, .rightMouseUp])
    }

    func testShieldRoutesScrollWheelInsideInteractiveZonesToChrome() throws {
        let harness = makeHarness()
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0)
        scrollEvent?.location = CGPoint(x: 20, y: 180)
        let event = try XCTUnwrap(scrollEvent.flatMap(NSEvent.init(cgEvent:)))
        let chrome = harness.controller.chromeWebView
        let viewportPoint = harness.controller.chromeInteractiveZones.viewportPoint(
            from: chrome.convert(event.locationInWindow, from: nil), in: chrome.bounds, isFlipped: chrome.isFlipped
        )
        harness.controller.chromeInteractiveZones.registerZones([
            (id: "chrome", rect: NSRect(x: viewportPoint.x - 10, y: viewportPoint.y - 10, width: 20, height: 20)),
        ])

        harness.shield.scrollWheel(with: event)

        XCTAssertEqual(harness.content.calls, [])
    }

    func testDoubleClickingContentInsetZoneMaximizesWindow() {
        let harness = makeHarness()
        harness.controller.chromeInteractiveZones.registerZones([(id: "content-inset-zone", rect: NSRect(x: 60, y: 0, width: 80, height: 10))])
        var maximizeCount = 0
        harness.controller.chromeWebView.maximizeWindow = { maximizeCount += 1 }

        harness.shield.mouseDown(with: harness.mouseEvent(.leftMouseDown, at: harness.insetPoint, clickCount: 2))

        XCTAssertEqual(maximizeCount, 1)
    }

    func testDraggingContentInsetZoneDragsWindow() {
        let harness = makeHarness()
        harness.controller.chromeInteractiveZones.registerZones([(id: "content-inset-zone", rect: NSRect(x: 60, y: 0, width: 80, height: 10))])
        var dragEvents: [NSEvent] = []
        harness.controller.chromeWebView.performWindowDrag = { dragEvents.append($0) }

        harness.shield.mouseDown(with: harness.mouseEvent(.leftMouseDown, at: harness.insetPoint))
        harness.shield.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, at: NSPoint(x: 90, y: harness.insetPoint.y - 5)))

        XCTAssertEqual(dragEvents.map(\.type), [.leftMouseDown])
    }

    /// WebKit applies a page's cursor only when the window hit-test lands on a descendant of that web view.
    func testChromeHitTestLandsInsideChromeWebViewSoWebKitAppliesItsCursor() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let controller = MainWindowController(context: browserContext.context)
        controller.setupViews()
        let contentView = controller.window!.contentView!
        let frameView = contentView.superview!
        controller.chromeInteractiveZones.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 100, width: 50, height: 50))])

        // Zones are in top-left viewport coordinates (below the title bar here); the content view is not flipped.
        let chromeWindowPoint = contentView.convert(NSPoint(x: 20, y: contentView.bounds.maxY - 120), to: nil)
        let hitOverChrome = frameView.hitTest(frameView.convert(chromeWindowPoint, from: nil))
        XCTAssertTrue(hitOverChrome === controller.chromeInput.shield)
        XCTAssertTrue(hitOverChrome?.isDescendant(of: controller.chromeWebView) == true)

        let contentWindowPoint = contentView.convert(NSPoint(x: contentView.bounds.maxX - 20, y: 20), to: nil)
        let hitOverContent = frameView.hitTest(frameView.convert(contentWindowPoint, from: nil))
        XCTAssertFalse(hitOverContent?.isDescendant(of: controller.chromeWebView) == true)
    }
}

/// A controller with its chrome, shield and a content sink filling the window, and a chrome zone at
/// the viewport's top-left 50pt square.
@MainActor
private struct PositionalHarness {
    let controller: MainWindowController
    let content: TestContentEventView
    var shield: ChromeInteractionShieldView { controller.chromeInput.shield }
    var height: CGFloat { controller.window!.contentView!.bounds.height }
    var chromePoint: NSPoint { NSPoint(x: 20, y: height - 20) }
    var contentPoint: NSPoint { NSPoint(x: 150, y: height - 150) }
    var insetPoint: NSPoint { NSPoint(x: 80, y: height - 5) }

    func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }
}

@MainActor
private func makeHarness() -> PositionalHarness {
    let controller = MainWindowController()
    controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
    let host = controller.window!.contentView!
    let content = TestContentEventView(frame: host.bounds)
    host.addSubview(content)
    controller.chromeWebView.frame = host.bounds
    host.addSubview(controller.chromeWebView)
    controller.chromeInput.shield.frame = controller.chromeWebView.bounds
    controller.chromeWebView.addSubview(controller.chromeInput.shield)
    controller.chromeInput.router.updateContentView(content)
    controller.chromeInteractiveZones.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 50))])
    return PositionalHarness(controller: controller, content: content)
}

@MainActor
private final class TestContentEventView: NSView {
    enum Call: Equatable {
        case rightMouseDown
        case rightMouseDragged
        case rightMouseUp
        case scrollWheel
    }

    var calls: [Call] = []

    override func rightMouseDown(with event: NSEvent) {
        calls.append(.rightMouseDown)
    }

    override func rightMouseDragged(with event: NSEvent) {
        calls.append(.rightMouseDragged)
    }

    override func rightMouseUp(with event: NSEvent) {
        calls.append(.rightMouseUp)
    }

    override func scrollWheel(with event: NSEvent) {
        calls.append(.scrollWheel)
    }
}
