import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeProcessRecoveryTests: XCTestCase {
    func testChromeTerminationReloadsAndResetsReadyHandshake() {
        let wc = MainWindowController()
        wc.didReceiveChromeReady = true
        wc.hasDispatchedChromeInitialState = true

        wc.webViewWebContentProcessDidTerminate(wc.chromeWebView)

        XCTAssertEqual(wc.chromeReloadAttempts.count, 1)
        XCTAssertFalse(wc.didReceiveChromeReady, "The reloaded chrome must re-run the ready handshake")
        XCTAssertFalse(wc.hasDispatchedChromeInitialState, "The reloaded chrome must receive the initial state again")
    }

    func testRepeatedTerminationsCapAtMaxAttempts() {
        let wc = MainWindowController()

        for _ in 0..<(MainWindowController.chromeReloadMaxAttempts + 2) {
            wc.webViewWebContentProcessDidTerminate(wc.chromeWebView)
        }

        XCTAssertEqual(wc.chromeReloadAttempts.count, MainWindowController.chromeReloadMaxAttempts)
    }

    func testAttemptsOutsideWindowArePruned() {
        let wc = MainWindowController()
        wc.chromeReloadAttempts = Array(
            repeating: Date(timeIntervalSinceNow: -MainWindowController.chromeReloadAttemptWindow - 1),
            count: MainWindowController.chromeReloadMaxAttempts
        )

        wc.webViewWebContentProcessDidTerminate(wc.chromeWebView)

        XCTAssertEqual(wc.chromeReloadAttempts.count, 1, "Stale attempts must expire so a later death still recovers")
    }

    func testChromeTerminationReleasesTheBridgeCallItNeverCompletes() {
        let wc = MainWindowController()
        wc.bridgeRouter = BridgeRouter(chromeWebView: wc.chromeWebView)
        var shipped: [String] = []
        var heldCompletions: [@MainActor () -> Void] = []
        wc.bridgeRouter.javaScriptSink = { _, arguments, completion in
            let messages = arguments["messages"] as? [[String: Any]] ?? (arguments["message"] as? [String: Any]).map { [$0] } ?? []
            shipped += messages.compactMap { $0["event"] as? String }
            heldCompletions.append(completion)
        }
        wc.bridgeRouter.send(event: "first")
        drainMainQueue()
        wc.bridgeRouter.send(event: "second")
        drainMainQueue()
        XCTAssertEqual(shipped, ["first"])

        wc.webViewWebContentProcessDidTerminate(wc.chromeWebView)
        XCTAssertEqual(shipped, ["first", "second"], "The reload must not leave the bridge waiting on the dead call")

        heldCompletions[0]()
        wc.bridgeRouter.send(event: "third")
        drainMainQueue()
        XCTAssertEqual(shipped, ["first", "second"], "A late completion of the dead call must not release the live one")

        heldCompletions[1]()
        XCTAssertEqual(shipped, ["first", "second", "third"])
    }

    func testNonChromeWebViewTerminationIsIgnored() {
        let wc = MainWindowController()
        wc.didReceiveChromeReady = true

        wc.webViewWebContentProcessDidTerminate(WKWebView())

        XCTAssertTrue(wc.chromeReloadAttempts.isEmpty)
        XCTAssertTrue(wc.didReceiveChromeReady)
    }
}
