import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class SplitPanesControllerTests: XCTestCase {
    private var browser: TemporaryBrowserContext!
    private var controller: MainWindowController!

    override func setUp() async throws {
        browser = try await TemporaryBrowserContext()
        let context = browser.context
        let space = try context.spaceManager!.createSpace(name: "Work", profileId: try context.profileManager!.createProfile(name: "Test").id)
        // Wide enough for WebKit to dock an inspector in half of it.
        controller = makeTestWindow(context, showing: space.id, size: NSSize(width: 1400, height: 800))
    }

    override func tearDown() async throws {
        browser.tearDown()
    }

    private func openTab(_ name: String) throws -> UUID {
        try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "data:text/html,\(name)"), activate: false)).id
    }

    private func view(_ id: UUID) throws -> NSView {
        try XCTUnwrap(controller.tabManager.loadedContentView(forTabId: id))
    }

    /// Opens the Web Inspector on a tab and returns its view once WebKit has docked it.
    private func dockInspector(on id: UUID) async throws -> NSView {
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: id))
        XCTAssertTrue(engine.showWebInspector())
        addTeardownBlock { @MainActor in _ = WebInspectorSupport.close(for: engine.wkWebView) }
        let inspector = try XCTUnwrap(WebInspectorSupport.connect(for: engine.wkWebView))
        for _ in 0..<250 where unsafe !engine.isWebInspectorVisible || inspector.superview == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(engine.isWebInspectorVisible)
        return inspector
    }

    func testASplitShowsOverThePageKeptForItsInspector() async throws {
        let inspected = try openTab("inspected"), left = try openTab("left"), right = try openTab("right")
        controller.activateTabStateFirst(id: left)
        controller.dropTab(right, at: nil, side: .edge(vertical: false, before: false))
        controller.activateTabStateFirst(id: inspected)
        let inspector = try await dockInspector(on: inspected)

        controller.activateTabStateFirst(id: left)

        let stack = controller.contentContainerView.subviews
        let kept = try [inspector, view(inspected)].map { view in try XCTUnwrap(stack.firstIndex { $0 === view }) }
        let panes = try [left, right].map { id in try XCTUnwrap(stack.firstIndex { $0 === (try? view(id)) }) }
        XCTAssertLessThan(try XCTUnwrap(kept.max()), try XCTUnwrap(panes.min()), "the kept page and its inspector stay under both panes")
    }

    func testAnInspectorDocksInsideItsPane() async throws {
        let inspected = try openTab("inspected"), other = try openTab("other")
        controller.activateTabStateFirst(id: inspected)
        controller.dropTab(other, at: nil, side: .edge(vertical: false, before: false))
        controller.activateTabStateFirst(id: inspected)
        let pane = try view(inspected).frame

        let inspector = try await dockInspector(on: inspected)

        let container: NSView = controller.contentContainerView
        let inspectorFrame = unsafe container.convert(inspector.frame, from: inspector.superview)
        XCTAssertTrue(pane.contains(inspectorFrame), "\(inspectorFrame) leaves the pane \(pane)")
        XCTAssertTrue(pane.contains(try view(inspected).frame))
        XCTAssertFalse(try view(inspected).frame.intersects(inspectorFrame))
        XCTAssertFalse(try view(other).frame.intersects(inspectorFrame))

        controller.closeSplitView(nil)

        XCTAssertTrue(unsafe inspector.superview === container, "the inspector docks beside the page again")
        XCTAssertTrue(controller.splitPanes.docks.isEmpty)
    }
}
