import XCTest
@testable import Lilo

@MainActor
final class WhatsNewStateTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "WhatsNewStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testFreshInstallSeedsTheVersionWithoutAnAnnouncement() {
        withDefaults { defaults in
            let state = WhatsNewState(defaults: defaults)
            XCTAssertFalse(state.reserveAutomatic(version: "1.2.3", freshInstall: true))
            XCTAssertFalse(WhatsNewState(defaults: defaults).reserveAutomatic(version: "1.2.3", freshInstall: false))
        }
    }

    func testAnEstablishedInstallReservesOnlyOneWindow() {
        withDefaults { defaults in
            let state = WhatsNewState(defaults: defaults)
            XCTAssertTrue(state.reserveAutomatic(version: "1.2.3", freshInstall: false))
            XCTAssertFalse(state.reserveAutomatic(version: "1.2.3", freshInstall: false))
        }
    }

    func testAnUnacknowledgedPresentationCanRetryOnTheNextLaunch() {
        withDefaults { defaults in
            XCTAssertTrue(WhatsNewState(defaults: defaults).reserveAutomatic(version: "1.2.3", freshInstall: false))
            XCTAssertTrue(WhatsNewState(defaults: defaults).reserveAutomatic(version: "1.2.3", freshInstall: false))
        }
    }

    func testAcknowledgmentSuppressesRelaunchAndDowngradeButAllowsANewerVersion() {
        withDefaults { defaults in
            let state = WhatsNewState(defaults: defaults)
            XCTAssertTrue(state.reserveAutomatic(version: "1.2.9", freshInstall: false))
            state.acknowledge(version: "1.2.9")
            XCTAssertFalse(WhatsNewState(defaults: defaults).reserveAutomatic(version: "1.2.9", freshInstall: false))
            XCTAssertFalse(WhatsNewState(defaults: defaults).reserveAutomatic(version: "1.2.8", freshInstall: false))
            XCTAssertTrue(WhatsNewState(defaults: defaults).reserveAutomatic(version: "1.2.10", freshInstall: false))
        }
    }

    func testManualAcknowledgmentCannotLowerTheMarker() {
        withDefaults { defaults in
            WhatsNewState(defaults: defaults).acknowledge(version: "2.0.0")
            WhatsNewState(defaults: defaults).acknowledge(version: "1.2.3")
            XCTAssertFalse(WhatsNewState(defaults: defaults).reserveAutomatic(version: "2.0.0", freshInstall: false))
        }
    }

    func testMalformedVersionsAndMismatchedAcknowledgmentsConsumeNothing() {
        withDefaults { defaults in
            for version in ["", "v1.2.3", "1.2", "1.2.3-beta", "1..3", "-1.2.3", "1.2.3\n"] {
                let state = WhatsNewState(defaults: defaults)
                XCTAssertFalse(state.reserveAutomatic(version: version, freshInstall: false), version)
                state.acknowledge(version: version)
            }
            let state = WhatsNewState(defaults: defaults)
            XCTAssertTrue(state.reserveAutomatic(version: "1.2.3", freshInstall: false))
            state.acknowledge(version: "9.0.0")
            XCTAssertTrue(WhatsNewState(defaults: defaults).reserveAutomatic(version: "1.2.3", freshInstall: false))
        }
    }
}
