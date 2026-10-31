import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeDragRoutingTests: XCTestCase {
    func testOverlayWebViewRelaysContentDestinationResultsOutsideInteractiveZones() {
        let harness = makeHarness()
        let drag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))

        harness.destination.draggingEnteredResult = .copy
        harness.destination.draggingUpdatedResult = .move
        harness.destination.prepareForDragOperationResult = true
        harness.destination.performDragOperationResult = true

        XCTAssertEqual(harness.overlay.draggingEntered(drag), .copy)
        XCTAssertEqual(harness.overlay.draggingUpdated(drag), .move)
        XCTAssertTrue(harness.overlay.prepareForDragOperation(drag))
        XCTAssertTrue(harness.overlay.performDragOperation(drag))
        harness.overlay.concludeDragOperation(drag)

        XCTAssertEqual(
            harness.destination.calls,
            [.draggingEntered, .draggingUpdated, .prepareForDragOperation, .performDragOperation, .concludeDragOperation]
        )
    }

    func testOverlayWebViewRefusesADropOnAPageUnderItsDialog() {
        let harness = makeHarness()
        let drag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))
        harness.destination.draggingEnteredResult = .copy
        harness.destination.performDragOperationResult = true
        harness.destination.addSubview(TabModalDialogView(title: "example.com says", message: "", acceptTitle: "OK", cancelTitle: nil) { _ in })

        XCTAssertEqual(harness.overlay.draggingEntered(drag), [])
        XCTAssertFalse(harness.overlay.performDragOperation(drag))
        XCTAssertTrue(harness.destination.calls.isEmpty, "the page under the dialog never sees the drop")
    }

    func testOverlayWebViewReentersContentDestinationWhenDragLeavesChromeZone() {
        let harness = makeHarness()
        let chromeDrag = TestDraggingInfo(location: NSPoint(x: 20, y: 180))
        let contentDrag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))

        harness.destination.draggingEnteredResult = .copy

        _ = harness.overlay.draggingEntered(chromeDrag)

        XCTAssertEqual(harness.overlay.draggingUpdated(contentDrag), .copy)
        XCTAssertEqual(harness.destination.calls, [.draggingEntered])
    }

    func testOverlayWebViewRoutesContentDragExit() {
        let harness = makeHarness()
        let drag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))

        _ = harness.overlay.draggingEntered(drag)
        harness.overlay.draggingExited(drag)

        XCTAssertEqual(harness.destination.calls, [.draggingEntered, .draggingExited])
    }

    func testOverlayWebViewKeepsChromePriorityInsideInteractiveZones() {
        let harness = makeHarness()
        let drag = TestDraggingInfo(location: NSPoint(x: 20, y: 180))

        _ = harness.overlay.draggingEntered(drag)
        _ = harness.overlay.draggingUpdated(drag)
        _ = harness.overlay.prepareForDragOperation(drag)
        _ = harness.overlay.performDragOperation(drag)
        harness.overlay.concludeDragOperation(drag)

        XCTAssertTrue(harness.destination.calls.isEmpty)
    }

    func testShieldForwardsToReplacementContentDestinationAfterControllerRelaySwap() {
        let harness = makeControllerHarness()
        let replacement = TestDragDestinationView(frame: harness.contentContainer.bounds)
        let drag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))

        harness.destination.draggingEnteredResult = .copy
        replacement.draggingEnteredResult = .move
        replacement.draggingUpdatedResult = .link

        harness.overlay.registerForDraggedTypes([.string])
        harness.controller.chromeInput.setContentView(harness.destination)

        XCTAssertEqual(Set(harness.shield.registeredDraggedTypes), Set(harness.overlay.registeredDraggedTypes))
        XCTAssertEqual(harness.shield.draggingEntered(drag), .copy)

        harness.controller.chromeInput.setContentView(replacement)

        XCTAssertEqual(harness.shield.draggingUpdated(drag), .move)
        XCTAssertEqual(harness.shield.draggingUpdated(drag), .link)
        XCTAssertEqual(harness.destination.calls, [.draggingEntered, .draggingExited])
        XCTAssertEqual(replacement.calls, [.draggingEntered, .draggingUpdated])
    }

    func testShieldCompletesExitAndReenterLifecycleWhenContentDestinationSwapsMidDrag() {
        let harness = makeControllerHarness()
        let replacement = TestDragDestinationView(frame: harness.contentContainer.bounds)
        let drag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))

        harness.destination.draggingEnteredResult = .copy
        replacement.draggingEnteredResult = .move
        replacement.draggingUpdatedResult = .link

        harness.overlay.registerForDraggedTypes([.string])
        harness.controller.chromeInput.setContentView(harness.destination)

        XCTAssertEqual(harness.shield.draggingEntered(drag), .copy)

        harness.controller.chromeInput.setContentView(replacement)

        XCTAssertEqual(harness.shield.draggingUpdated(drag), .move)
        XCTAssertEqual(harness.shield.draggingUpdated(drag), .link)
        harness.shield.draggingExited(drag)

        XCTAssertEqual(harness.destination.calls, [.draggingEntered, .draggingExited])
        XCTAssertEqual(replacement.calls, [.draggingEntered, .draggingUpdated, .draggingExited])
    }

    func testShieldPrepareForDragOperationDoesNotDuplicateExitWhenContentDestinationSwapsMidDrag() {
        let harness = makeControllerHarness()
        let replacement = TestDragDestinationView(frame: harness.contentContainer.bounds)
        let drag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))

        harness.destination.draggingEnteredResult = .copy
        replacement.draggingEnteredResult = .move
        replacement.prepareForDragOperationResult = true

        harness.overlay.registerForDraggedTypes([.string])
        harness.controller.chromeInput.setContentView(harness.destination)

        XCTAssertEqual(harness.shield.draggingEntered(drag), .copy)

        harness.controller.chromeInput.setContentView(replacement)

        XCTAssertTrue(harness.shield.prepareForDragOperation(drag))

        XCTAssertEqual(harness.destination.calls, [.draggingEntered, .draggingExited])
        XCTAssertEqual(replacement.calls, [.draggingEntered, .prepareForDragOperation])
    }

    func testShieldPerformDragOperationDoesNotDuplicateExitWhenContentDestinationSwapsMidDrag() {
        let harness = makeControllerHarness()
        let replacement = TestDragDestinationView(frame: harness.contentContainer.bounds)
        let drag = TestDraggingInfo(location: NSPoint(x: 150, y: 150))

        harness.destination.draggingEnteredResult = .copy
        replacement.draggingEnteredResult = .move
        replacement.performDragOperationResult = true

        harness.overlay.registerForDraggedTypes([.string])
        harness.controller.chromeInput.setContentView(harness.destination)

        XCTAssertEqual(harness.shield.draggingEntered(drag), .copy)

        harness.controller.chromeInput.setContentView(replacement)

        XCTAssertTrue(harness.shield.performDragOperation(drag))

        XCTAssertEqual(harness.destination.calls, [.draggingEntered, .draggingExited])
        XCTAssertEqual(replacement.calls, [.draggingEntered, .performDragOperation])
    }

    func testShieldRequestsPeriodicDraggingUpdates() {
        let harness = makeControllerHarness()
        XCTAssertTrue(harness.shield.wantsPeriodicDraggingUpdates())
    }

    /// The sidebar opens dropped links and files, which WebKit's drop events cannot name: the window sends them as the drag
    /// enters the chrome, and takes them back as it leaves.
    func testDragOffersItsLinksToTheChromeWhileOverIt() async throws {
        let harness = makeControllerHarness()
        let router = BridgeRouter(chromeWebView: harness.controller.chromeWebView)
        var offers: [[String: Any]] = []
        router.javaScriptSink = { _, arguments, completion in
            let messages = arguments["messages"] as? [[String: Any]] ?? (arguments["message"] as? [String: Any]).map { [$0] } ?? []
            offers += messages.filter { $0["event"] as? String == "linkDrag" }
            completion()
        }
        harness.controller.bridgeRouter = router
        harness.controller.chromeInteractiveZones.registerZones([(id: "sidebar", rect: NSRect(x: 0, y: 0, width: 50, height: 50))])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Some Notes.html").resolvingSymlinksInPath()
        try Data().write(to: file)
        // As Finder writes a file: by reference.
        let reference = try XCTUnwrap((file as NSURL).fileReferenceURL())

        let fileDrag = TestDraggingInfo(location: NSPoint(x: 20, y: 180))
        fileDrag.draggingSequenceNumber = 1
        fileDrag.draggingPasteboard.writeObjects([reference as NSURL, URL(string: "https://example.com/a")! as NSURL])
        _ = harness.shield.draggingEntered(fileDrag)
        harness.shield.draggingExited(fileDrag)

        let textDrag = TestDraggingInfo(location: NSPoint(x: 20, y: 180))
        textDrag.draggingSequenceNumber = 2
        textDrag.draggingPasteboard.setString("example.com", forType: .string)
        _ = harness.shield.draggingEntered(textDrag)
        harness.shield.draggingExited(textDrag)

        let arrived = await pollUntil { offers.count == 4 }
        XCTAssertTrue(arrived)
        let offered = (offers.first?["urls"] as? [String] ?? []).compactMap(URL.init(string:))
        XCTAssertEqual(offered.map { $0.isFileURL ? $0.resolvingSymlinksInPath() : $0 }, [file, URL(string: "https://example.com/a")!])
        XCTAssertEqual(offers.map { $0["text"] as? String }, ["", "", "example.com", ""])
        XCTAssertEqual(offers.map { ($0["urls"] as? [String])?.count }, [2, 0, 0, 0])
    }

    private func makeHarness() -> OverlayHarness {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()

        let overlay = OverlayWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let destination = TestDragDestinationView(frame: overlay.bounds)
        let router = ChromeEventRouter(zoneStore: ChromeInteractiveZoneStore(), captureMachine: ChromeCaptureMachine())
        router.zoneStore.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 50))])
        overlay.eventRouter = router
        router.updateContentView(destination)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: overlay.bounds)
        window.contentView?.addSubview(overlay)
        // Let the web process finish forwarded drags while the page exists, or WebKit kills it and crashes the host.
        addTeardownBlock { @MainActor in _ = try? await overlay.evaluateJavaScript("0") }

        return OverlayHarness(window: window, overlay: overlay, destination: destination)
    }

    private func makeControllerHarness() -> ControllerHarness {
        let controller = MainWindowController()
        let window = controller.window!
        let contentContainer = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let destination = TestDragDestinationView(frame: contentContainer.bounds)
        let overlay = controller.chromeWebView
        let shield = controller.chromeInput.shield
        overlay.frame = contentContainer.bounds
        shield.frame = contentContainer.bounds

        contentContainer.addSubview(destination)
        window.contentView?.addSubview(contentContainer)
        window.contentView?.addSubview(overlay)
        contentContainer.addSubview(shield)
        controller.contentContainerView = contentContainer

        return ControllerHarness(
            controller: controller,
            window: window,
            contentContainer: contentContainer,
            overlay: overlay,
            shield: shield,
            destination: destination
        )
    }
}

private struct OverlayHarness {
    let window: NSWindow
    let overlay: OverlayWebView
    let destination: TestDragDestinationView
}

private struct ControllerHarness {
    let controller: MainWindowController
    let window: NSWindow
    let contentContainer: NSView
    let overlay: OverlayWebView
    let shield: ChromeInteractionShieldView
    let destination: TestDragDestinationView
}

@MainActor
private final class TestDragDestinationView: NSView {
    enum Call: Equatable {
        case draggingEntered
        case draggingUpdated
        case draggingExited
        case prepareForDragOperation
        case performDragOperation
        case concludeDragOperation
    }

    var calls: [Call] = []
    var draggingEnteredResult: NSDragOperation = []
    var draggingUpdatedResult: NSDragOperation = []
    var prepareForDragOperationResult = false
    var performDragOperationResult = false

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        calls.append(.draggingEntered)
        return draggingEnteredResult
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        calls.append(.draggingUpdated)
        return draggingUpdatedResult
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        calls.append(.draggingExited)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        calls.append(.prepareForDragOperation)
        return prepareForDragOperationResult
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        calls.append(.performDragOperation)
        return performDragOperationResult
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        calls.append(.concludeDragOperation)
    }
}

@MainActor
private final class TestDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("ChromeDragRoutingTests"))

    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy]
    var draggedImageLocation: NSPoint = .zero
    var draggedImage: NSImage?
    var draggingSource: Any?
    var draggingSequenceNumber: Int = 0
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop: Int = 0
    var springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(location: NSPoint) {
        self.draggingLocation = location
        super.init()
        draggingPasteboard.clearContents()
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
