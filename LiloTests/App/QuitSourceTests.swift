import AppKit
import XCTest
@testable import Lilo

@MainActor
final class QuitSourceTests: XCTestCase {
    func testAnAppleEventNamesTheAppThatSentIt() {
        XCTAssertEqual(QuitSource.describe(isAppleEvent: true, sender: "com.example.app", eventType: .keyDown, isQuitKey: false),
                       "an Apple Event from com.example.app")
        XCTAssertEqual(QuitSource.describe(isAppleEvent: true, sender: nil, eventType: nil, isQuitKey: false),
                       "an Apple Event from an unknown process")
    }

    func testAKeyIsNeverNamedBeyondBeingTheQuitKey() {
        XCTAssertEqual(QuitSource.describe(isAppleEvent: false, sender: nil, eventType: .keyDown, isQuitKey: true), "the Q key")
        XCTAssertEqual(QuitSource.describe(isAppleEvent: false, sender: nil, eventType: .keyDown, isQuitKey: false), "another key")
    }

    func testWithoutAnEventTheRequestCameFromLilo() {
        XCTAssertEqual(QuitSource.describe(isAppleEvent: false, sender: nil, eventType: .leftMouseUp, isQuitKey: false), "a click")
        XCTAssertEqual(QuitSource.describe(isAppleEvent: false, sender: nil, eventType: nil, isQuitKey: false), "Lilo itself")
    }

    func testOnlyAToolLiloOffersReachesTheLog() {
        XCTAssertEqual(QuitSource.describe(tool: "computer", secondsAgo: 2.4, known: ["computer"]), "agent tool computer ran 2 s before")
        XCTAssertEqual(QuitSource.describe(tool: "a secret a client sent", secondsAgo: 2, known: ["computer"]), "no agent tool ran")
        XCTAssertEqual(QuitSource.describe(tool: nil, secondsAgo: nil, known: ["computer"]), "no agent tool ran")
    }
}
