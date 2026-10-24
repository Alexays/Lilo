import AppKit
import Foundation

/// Resolves HTTP basic/digest authentication challenges: keychain lookup, an NSAlert
/// username/password prompt on a miss, and retry accounting via `previousFailureCount`.
/// TLS server-trust is handled by the tab directly (it needs the navigation context), not here.
@MainActor
struct HTTPAuthChallengeHandler {
    /// `completion` runs exactly once, on the main actor. The prompt is a sheet on `window`;
    /// without a window it falls back to an app-modal alert. A private data store passes
    /// `usesKeychain: false`, so what is typed there never outlives the session.
    func resolve(
        _ challenge: URLAuthenticationChallenge,
        in window: NSWindow?,
        usesKeychain: Bool,
        completion: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let storedCredential = usesKeychain ? HTTPAuthKeychain.storedCredential(for: space) : nil
        if challenge.previousFailureCount == 0, let storedCredential {
            completion(.useCredential, storedCredential)
            return
        }

        if usesKeychain, challenge.previousFailureCount > 0 {
            HTTPAuthKeychain.delete(for: space)
        }

        prompt(challenge, storedCredential: storedCredential, in: window) { credential in
            guard let credential else {
                completion(.cancelAuthenticationChallenge, nil)
                return
            }
            if usesKeychain { HTTPAuthKeychain.store(credential, for: space) }
            completion(.useCredential, credential)
        }
    }

    private func prompt(
        _ challenge: URLAuthenticationChallenge,
        storedCredential: URLCredential?,
        in window: NSWindow?,
        completion: @escaping @MainActor @Sendable (URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let realm = space.realm ?? "Restricted Area".localized
        let host = space.host

        let usernameField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        usernameField.placeholderString = "Username".localized
        usernameField.stringValue = challenge.proposedCredential?.user ?? storedCredential?.user ?? ""

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Password".localized

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        accessory.addSubview(usernameField)
        accessory.addSubview(passwordField)

        let alert = NSAlert()
        alert.messageText = "Authentication Required".localized
        if challenge.previousFailureCount > 0 {
            alert.informativeText = String(format: "Saved credentials were rejected by %@.\nRealm: %@".localized, host, realm)
        } else {
            alert.informativeText = String(format: "%@ requires a username and password.\nRealm: %@".localized, host, realm)
        }
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Log In".localized)
        alert.addButton(withTitle: "Cancel".localized)

        let finish: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(URLCredential(
                user: usernameField.stringValue,
                password: passwordField.stringValue,
                persistence: .forSession
            ))
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
