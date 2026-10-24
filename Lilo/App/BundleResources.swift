import Foundation

extension Bundle {
    /// Bundled runtime resources (injected JS, content-blocker rules) live in `Bundle.main` inside
    /// the app bundle, but SwiftPM builds (`swift test`, `swift run`) place them in the generated
    /// module bundle instead, where `Bundle.main` cannot see them.
    static func appResourceURL(_ name: String, extension ext: String?) -> URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        #else
        Bundle.main.url(forResource: name, withExtension: ext)
        #endif
    }
}

extension ProcessInfo {
    /// SPM's `swift test` does not set XCTestConfigurationFilePath, so also check for the framework.
    static let isRunningUnderXCTest = processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}

extension UserDefaults {
    /// Lilo's defaults, thread-safe as `.standard` is. Every test host of every checkout shares one bundle id:
    /// each gets a domain of its own instead, empty at start, that the next run's TestRunCleanup removes.
    nonisolated(unsafe) static let lilo: UserDefaults = {
        guard ProcessInfo.isRunningUnderXCTest else { return .standard }
        let name = "\(testDomainPrefix)\(getpid())"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    static let testDomainPrefix = "\(Bundle.main.bundleIdentifier ?? "fr.arouillard.lilo.tests").pid"
}
