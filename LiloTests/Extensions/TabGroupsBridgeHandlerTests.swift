import XCTest
@testable import Lilo

/// `TabGroupsBridgeHandler` bridges chrome.tabGroups onto Lilo's tab-folder model. The behavior that
/// touches live tab state needs a window; here we lock down the pure translation logic (the Chrome
/// color palette mapping) and the fail-closed behavior when no window context is available.
@MainActor
final class TabGroupsBridgeHandlerTests: XCTestCase {

    func test_handledActions() {
        let handler = TabGroupsBridgeHandler(contextProvider: { _ in nil })
        XCTAssertEqual(handler.gapActions, [
            "tabGroups.query", "tabGroups.get", "tabGroups.update", "tabGroups.move",
            "tabs.group", "tabs.ungroup", "tabs.discard", "tabs.details"
        ])
    }

    func test_hexForChromeColor_knownNames() {
        XCTAssertEqual(TabGroupsBridgeHandler.hex(forChromeColor: "cyan"), "#007b83")
        XCTAssertEqual(TabGroupsBridgeHandler.hex(forChromeColor: "RED"), "#d93025") // case-insensitive
        XCTAssertNil(TabGroupsBridgeHandler.hex(forChromeColor: "mauve"))            // not a Chrome color
    }

    func test_chromeColorForHex_nearestMatch() {
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "#d93025"), "red")    // exact palette hit
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "#ff0000"), "red")    // nearest to pure red
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "#00ff00"), "green")  // nearest to pure green
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "garbage"), "grey")   // unparseable falls back to a safe default
    }

    func test_chromeColorForHex_liloDefaultFolderColorMapsToAValidName() {
        // Lilo's default folder color sits between blue and purple; it must still map to a real Chrome color name.
        let name = TabGroupsBridgeHandler.chromeColor(forHex: "#5865f2")
        XCTAssertTrue(["blue", "purple"].contains(name), "expected blue/purple, got \(name)")
    }

    func test_colorRoundTripsThroughTheChromePalette() {
        for color in ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"] {
            let hex = try? XCTUnwrap(TabGroupsBridgeHandler.hex(forChromeColor: color))
            XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: hex ?? ""), color, "round-trip failed for \(color)")
        }
    }

    func test_noWindowContext_failsClosed() async throws {
        let handler = TabGroupsBridgeHandler(contextProvider: { _ in nil })
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "tabGroups.query"]))
        let result = await handler.handle(msg)
        XCTAssertTrue(result is BridgeError, "expected a BridgeError when no window is active")
    }
}
