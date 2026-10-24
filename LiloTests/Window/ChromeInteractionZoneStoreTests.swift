import AppKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeInteractionZoneStoreTests: XCTestCase {

    // MARK: - isInteractive (no bounding-box pre-filter)

    func testIsInteractiveReturnsTrueWhenPointIsInsideZone() {
        let store = ChromeInteractiveZoneStore()
        store.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 30))])
        // isFlipped: true keeps the point as is; unflipped, y=10 would map to 190, outside the zone.
        XCTAssertTrue(store.isInteractive(NSPoint(x: 10, y: 10), in: NSRect(x: 0, y: 0, width: 200, height: 200), isFlipped: true))
    }

    func testIsInteractiveReturnsFalseWhenPointIsOutsideAllZones() {
        let store = ChromeInteractiveZoneStore()
        store.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 30))])
        XCTAssertFalse(store.isInteractive(NSPoint(x: 100, y: 100), in: NSRect(x: 0, y: 0, width: 200, height: 200), isFlipped: true))
    }

    func testIsInteractiveAfterRemovingZoneReturnsFalse() {
        let store = ChromeInteractiveZoneStore()
        store.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 30))])
        store.removeZone(id: "chrome")
        XCTAssertFalse(store.isInteractive(NSPoint(x: 10, y: 10), in: NSRect(x: 0, y: 0, width: 200, height: 200), isFlipped: true))
    }

    func testRegisterZonesIsDeduplicated() {
        var notificationCount = 0
        let store = ChromeInteractiveZoneStore()
        store.onZonesChanged = { _ in notificationCount += 1 }
        store.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 30))])
        store.registerZones([(id: "chrome", rect: NSRect(x: 0, y: 0, width: 50, height: 30))])
        XCTAssertEqual(notificationCount, 1, "Registering the same zone twice should only notify once")
    }

    func testIsInteractiveHandlesMultipleZones() {
        let store = ChromeInteractiveZoneStore()
        store.registerZones([
            (id: "a", rect: NSRect(x: 0, y: 0, width: 20, height: 20)),
            (id: "b", rect: NSRect(x: 100, y: 100, width: 20, height: 20)),
        ])
        XCTAssertTrue(store.isInteractive(NSPoint(x: 5, y: 5), in: NSRect(x: 0, y: 0, width: 200, height: 200), isFlipped: true))
        XCTAssertTrue(store.isInteractive(NSPoint(x: 105, y: 105), in: NSRect(x: 0, y: 0, width: 200, height: 200), isFlipped: true))
        XCTAssertFalse(store.isInteractive(NSPoint(x: 50, y: 50), in: NSRect(x: 0, y: 0, width: 200, height: 200), isFlipped: true))
    }
}
