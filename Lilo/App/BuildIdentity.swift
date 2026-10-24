import Foundation

/// Who this build is: a Debug build never shares the installed app's data, socket, helper or keychain items.
/// Shared by the app, `lilo-mcp` and the power helper; Debug's identifier matches LILO_BUNDLE_ID_SUFFIX in project.yml.
enum BuildIdentity {
    #if DEBUG
    static let appIdentifier = "fr.arouillard.lilo.debug"
    static let dataFolderName = "Lilo-Debug"
    #else
    static let appIdentifier = "fr.arouillard.lilo"
    static let dataFolderName = "Lilo"
    #endif

    /// ~/Library/Application Support/<dataFolderName>; a non-empty LILO_APP_SUPPORT_DIR environment
    /// variable overrides it so tests and benchmarks can redirect all persistence, the agent socket included.
    static var appSupportDirectory: String {
        if let override = ProcessInfo.processInfo.environment["LILO_APP_SUPPORT_DIR"], !override.isEmpty {
            return override
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(dataFolderName).path
    }

    /// ~/Downloads, or Downloads inside LILO_APP_SUPPORT_DIR: an isolated run never writes to the user's folders.
    static var defaultDownloadsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["LILO_APP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
