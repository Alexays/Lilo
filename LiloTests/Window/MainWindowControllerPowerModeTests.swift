import AppKit
import XCTest
@testable import Lilo

@MainActor
final class MainWindowControllerPowerModeTests: XCTestCase {
    // The lifecycle observers are wired (and the initial state applied) during init, before
    // setupBridgeEarly() creates the bridge, so a constrained-power callback (Low Power Mode / thermal
    // pressure) that runs that early must tolerate a nil `bridgeRouter` instead of trapping on it.
    func testConstrainedPowerCallbackBeforeBridgeDoesNotCrash() {
        let wc = MainWindowController()
        // Precondition: under XCTest, init returns before runStartupSequence, so the bridge that
        // setupBridgeEarly() would create is absent: exactly the early window under test.
        XCTAssertNil(wc.bridgeRouter as BridgeRouter?, "Bridge must be absent to exercise the early path")

        // Simulate the OS reporting constrained power before the bridge is ready.
        wc.context.hiddenSpaceLifecycle.onConstrainedPowerChange?(true)

        // Engine suppression still takes effect even without a bridge to notify the chrome.
        XCTAssertTrue(wc.context.engineFactory.suppressWarmPool)
    }

    // Coming back to the front rebuilds, off the activation path, the warm view a long absence released.
    // An empty pool stays empty: the activation at launch spawns no speculative process.
    func testForegroundingRebuildsOnlyAReleasedWarmPool() async {
        let wc = MainWindowController()
        let factory = wc.context.engineFactory
        let lifecycle = wc.context.hiddenSpaceLifecycle
        // Built first: building it applies Low Power Mode, which keeps the pool off on a Mac running in it.
        factory.suppressWarmPool = false
        factory.dropWarmPool()
        lifecycle.onForegrounded?()
        let filledUnasked = await pollUntil(timeout: 0.6) { factory.test_warmPoolCount > 0 }
        XCTAssertFalse(filledUnasked, "nothing was released, so nothing is rebuilt")

        factory.rearmWarmPool(dataStore: factory.defaultDataStore(), profileId: nil)
        let filled = await pollUntil { factory.test_warmPoolCount == 1 }
        XCTAssertTrue(filled, "the warm pool fills")
        factory.releaseWarmPool(after: .zero)
        let released = await pollUntil { factory.test_warmPoolCount == 0 }
        XCTAssertTrue(released, "the release drops it")

        lifecycle.onForegrounded?()
        XCTAssertEqual(factory.test_warmPoolCount, 0, "the refill must not run on activation")
        let refilled = await pollUntil { factory.test_warmPoolCount == 1 }
        XCTAssertTrue(refilled, "the pool refills once the activation is over")
    }

    // A quick app switch must not throw away the warm process only to rebuild it on the way back.
    func testBackgroundingKeepsTheWarmPoolForAWhile() async {
        let wc = MainWindowController()
        let factory = wc.context.engineFactory
        let lifecycle = wc.context.hiddenSpaceLifecycle
        // Built first: building it applies Low Power Mode, which keeps the pool off on a Mac running in it.
        factory.suppressWarmPool = false
        factory.rearmWarmPool(dataStore: factory.defaultDataStore(), profileId: nil)
        let filled = await pollUntil { factory.test_warmPoolCount == 1 }
        XCTAssertTrue(filled, "the warm pool fills")

        lifecycle.onBackgrounded?()

        XCTAssertEqual(wc.context.engineFactory.test_warmPoolCount, 1)
    }
}
