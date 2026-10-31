import AppKit
import Foundation

/// Resolves HTTP basic/digest authentication challenges: keychain lookup, a tab-modal username/password prompt on a
/// miss, and retry accounting via `previousFailureCount`. A password reaches the keychain only when the user ticks
/// "Remember this password". TLS server-trust is handled by the tab directly (it needs the navigation context), not here.
@MainActor
struct HTTPAuthChallengeHandler {
    /// `completion` runs exactly once, on the main actor. The prompt goes to `present`, which covers the page's tab
    /// with it. Saved credentials belong to `keychainProfile`; a private data store passes nil, so what is typed
    /// there never outlives the session.
    func resolve(
        _ challenge: URLAuthenticationChallenge,
        keychainProfile: UUID?,
        present: (TabModalDialogView) -> Void,
        completion: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let storedCredential = keychainProfile.flatMap { HTTPAuthKeychain.storedCredential(for: space, profileId: $0) }
        if challenge.previousFailureCount == 0, let storedCredential {
            completion(.useCredential, storedCredential)
            return
        }

        if let keychainProfile, challenge.previousFailureCount > 0 {
            HTTPAuthKeychain.delete(for: space, profileId: keychainProfile)
        }

        let realm = space.realm ?? "Restricted Area".localized
        let message = challenge.previousFailureCount > 0
            ? String(format: "Saved credentials were rejected by %@.\nRealm: %@".localized, space.host, realm)
            : String(format: "%@ requires a username and password.\nRealm: %@".localized, space.host, realm)

        let usernameField = NSTextField(string: challenge.proposedCredential?.user ?? storedCredential?.user ?? "")
        usernameField.placeholderString = "Username".localized
        usernameField.setAccessibilityLabel("Username".localized)
        usernameField.contentType = .username
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "Password".localized
        passwordField.setAccessibilityLabel("Password".localized)
        passwordField.contentType = .password
        // Ticked when the credentials being replaced were remembered.
        let rememberBox = NSButton(checkboxWithTitle: "Remember this password".localized, target: nil, action: nil)
        rememberBox.state = storedCredential == nil ? .off : .on

        let accessories: [NSView] = [usernameField, passwordField] + (keychainProfile == nil ? [] : [rememberBox])
        present(TabModalDialogView(
            title: "Authentication Required".localized,
            message: message,
            accessories: accessories,
            acceptTitle: "Log In".localized,
            cancelTitle: "Cancel".localized
        ) { accepted in
            guard accepted else { return completion(.cancelAuthenticationChallenge, nil) }
            let credential = URLCredential(user: usernameField.stringValue, password: passwordField.stringValue, persistence: .forSession)
            if rememberBox.state == .on, let keychainProfile { HTTPAuthKeychain.store(credential, for: space, profileId: keychainProfile) }
            completion(.useCredential, credential)
        })
    }
}
