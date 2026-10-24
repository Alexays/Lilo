import AppKit

/// Reports and requests Lilo's status as the default browser; works without entitlements because the app is unsandboxed and
/// `Info.plist` declares `http`/`https` handling.
@MainActor
enum DefaultBrowserService {

    static func isDefault() -> Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            return false
        }
        // By identity, not path: a copy still on the disk image, or LaunchServices' pick among two copies, is still Lilo.
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func requestDefault(completion: @escaping @MainActor (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        // The user's answer to macOS's prompt comes back as these errors.
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { httpError in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { httpsError in
                let accepted = httpError == nil && httpsError == nil
                Task { @MainActor in completion(accepted || isDefault()) }
            }
        }
    }
}
