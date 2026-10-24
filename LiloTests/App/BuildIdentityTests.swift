import XCTest
@testable import Lilo

final class BuildIdentityTests: XCTestCase {
    func testDebugBuildsKeepClearOfTheInstalledAppsDataAndHelper() throws {
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
}
