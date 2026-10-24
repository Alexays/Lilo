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
        return handler.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    static func requestDefault(completion: @escaping @MainActor (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                Task { @MainActor in completion(isDefault()) }
            }
        }
    }
}
