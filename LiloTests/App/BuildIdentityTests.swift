import XCTest
@testable import Lilo
import Sparkle

final class BuildIdentityTests: XCTestCase {
    @MainActor func testDebugBuildsKeepClearOfTheInstalledAppsDataAndHelper() throws {
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["LILO_APP_SUPPORT_DIR"]
        unsetenv("LILO_APP_SUPPORT_DIR")
        defer { if let override { setenv("LILO_APP_SUPPORT_DIR", override, 1) } else { unsetenv("LILO_APP_SUPPORT_DIR") } }

        XCTAssertEqual(BuildIdentity.appIdentifier, "fr.arouillard.lilo.debug")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(BuildIdentity.appSupportDirectory, support.appending(path: "Lilo-Debug").path)
        XCTAssertEqual(AgentControl.defaultSocketURL.deletingLastPathComponent().lastPathComponent, "Lilo-Debug")
        XCTAssertEqual(PowerHelperIdentity.machService, "fr.arouillard.lilo.debug.power")

        setenv("LILO_APP_SUPPORT_DIR", "/tmp/lilo-elsewhere", 1)
        XCTAssertEqual(BuildIdentity.appSupportDirectory, "/tmp/lilo-elsewhere")

        // The Debug app ships only its own launch daemon, the one PowerHelperIdentity registers.
        let daemons = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchDaemons")
        guard FileManager.default.fileExists(atPath: daemons.path) else { throw XCTSkip("the launch daemons ship only in the Xcode-built app") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: daemons.path), [PowerHelperIdentity.plistName])
        #else
        throw XCTSkip("a Release build keeps the installed app's identity")
        #endif
    }

    /// Sparkle's updater refuses to start, so no build would ever check for updates, when a signed feed lacks this pair.
    func testASignedUpdateFeedAlsoVerifiesUpdatesBeforeExtraction() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    }

    /// A cached `releases/latest` redirect would hand an update check the previous release's appcast.
    func testEachUpdateCheckAsksForTheFeedAfresh() throws {
        let feed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        let url = try XCTUnwrap(delegate.feedURLString(for: updater))
        XCTAssertTrue(url.hasPrefix(feed + "?check="), url)
    }

    func testUpdatesAreCheckedAndDownloadedInTheBackgroundFromTheFirstLaunch() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
    }

    /// The sidebar's Restart runs Sparkle's install block; taking it also keeps Sparkle's own alert away.
    @MainActor func testADownloadedUpdateWaitsForTheSidebarsRestart() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        defer { delegate.readyUpdate = nil }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        var installed = false

        XCTAssertTrue(delegate.updater(updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: { installed = true }))
        delegate.readyUpdate?.install()

        XCTAssertTrue(installed)
    }
}
