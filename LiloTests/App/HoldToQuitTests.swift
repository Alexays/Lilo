import AppKit
import XCTest
@testable import Lilo

@MainActor
final class HoldToQuitTests: XCTestCase {
    private var hold: HoldToQuit!
    private var enabled = true
    private var quits = 0

    override func setUp() {
        super.setUp()
        enabled = true
        quits = 0
        hold = HoldToQuit()
        hold.isEnabled = { [weak self] in self?.enabled == true }
        hold.quit = { [weak self] in self?.quits += 1 }
        hold.holdDuration = 0.05
    }

    override func tearDown() {
        KeyboardShortcuts.applyPreset("lilo", store: nil)
        hold = nil
        super.tearDown()
    }

    private func key(_ type: NSEvent.EventType, _ characters: String = "q",
                     _ flags: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 12, isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode)!
    }

    func testTheQuitKeyReachesTheMenusWhileOff() {
        enabled = false
        XCTAssertFalse(hold.handle(key(.keyDown)))
        XCTAssertFalse(hold.isHolding)
    }

    func testAPressBeginsAHoldAndItsRepeatStaysSwallowed() {
        XCTAssertTrue(hold.handle(key(.keyDown)))
        XCTAssertTrue(hold.isHolding)
        XCTAssertTrue(hold.handle(key(.keyDown, isRepeat: true)))
        XCTAssertTrue(hold.isHolding)
    }

    func testReleasingTheKeyCancelsTheHold() {
        _ = hold.handle(key(.keyDown))
        XCTAssertTrue(hold.handle(key(.keyUp)))
        XCTAssertFalse(hold.isHolding)
    }

    func testReleasingCommandCancelsTheHold() {
        _ = hold.handle(key(.keyDown))
        XCTAssertFalse(hold.handle(key(.flagsChanged, "", [])))
        XCTAssertFalse(hold.isHolding)
    }

    func testAnUnrelatedKeyReleaseKeepsTheHold() {
        _ = hold.handle(key(.keyDown))
        XCTAssertFalse(hold.handle(key(.keyUp, "x", .command, keyCode: 7)))
        XCTAssertTrue(hold.isHolding)
    }

    func testHoldingThroughTheDeadlineQuitsOnce() {
        _ = hold.handle(key(.keyDown))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(quits, 1)
        XCTAssertFalse(hold.isHolding)
        // The keys are still down: their repeats and the same press must not begin a second hold.
        XCTAssertTrue(hold.handle(key(.keyDown)))
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(quits, 1)
        // After a real release the next press is a fresh hold.
        _ = hold.handle(key(.keyUp))
        XCTAssertTrue(hold.handle(key(.keyDown)))
        XCTAssertTrue(hold.isHolding)
    }

    func testAReboundQuitShortcutHoldsAndCancelsOnItsOwnKeys() {
        KeyboardShortcuts.set("app.quit", to: ["⌥⇧k"], store: nil)
        XCTAssertTrue(hold.handle(key(.keyDown, "k", [.option, .shift], keyCode: 40)))
        XCTAssertTrue(hold.isHolding)
        // Letting a modifier of the combo go cancels.
        XCTAssertFalse(hold.handle(key(.flagsChanged, "", .shift)))
        XCTAssertFalse(hold.isHolding)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(quits, 0)
    }
}
