import AppKit
import XCTest
@testable import Lilo

@MainActor
final class HeadlessTests: XCTestCase {
    func testTheBackgroundFlagStartsTheAgentHost() {
        XCTAssertTrue(Headless.requested(arguments: ["/Applications/Lilo.app/Contents/MacOS/Lilo", "--background"], environment: [:]))
        XCTAssertFalse(Headless.requested(arguments: ["/Applications/Lilo.app/Contents/MacOS/Lilo"], environment: [:]))
        XCTAssertFalse(Headless.requested(arguments: ["--background"], environment: [:]), "the executable's own path is no flag")
    }

    #if DEBUG
    func testADebugBuildAlsoReadsTheEnvironment() {
        XCTAssertTrue(Headless.requested(arguments: ["Lilo"], environment: ["LILO_HEADLESS": "1"]))
        XCTAssertFalse(Headless.requested(arguments: ["Lilo"], environment: ["LILO_HEADLESS": "0"]))
    }
    #endif

    /// Entering hides the window from the user without closing it; leaving gives it back. The test host keeps
    /// its own activation policy either way.
    func testTheBackgroundConcealsTheWindowUntilLeft() {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in
            Headless.isOn = false
            window.close()
        }
        let policy = NSApp.activationPolicy()

        Headless.enter(concealing: window)
        XCTAssertTrue(Headless.isOn)
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(window.collectionBehavior.contains(.transient))

        Headless.leave(revealing: [window])
        XCTAssertFalse(Headless.isOn)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.collectionBehavior.contains(.transient))
        XCTAssertEqual(NSApp.activationPolicy(), policy)
    }
}
