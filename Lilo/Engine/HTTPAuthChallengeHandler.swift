import AppKit
import Foundation

/// Resolves HTTP basic/digest authentication challenges: keychain lookup, an NSAlert
/// username/password prompt on a miss, and retry accounting via `previousFailureCount`.
/// A password reaches the keychain only when the user ticks "Remember this password".
/// TLS server-trust is handled by the tab directly (it needs the navigation context), not here.
@MainActor
struct HTTPAuthChallengeHandler {
    /// `completion` runs exactly once, on the main actor. The prompt is a sheet on the window `whenShown`
    /// hands over once the page's tab shows; without one the challenge is cancelled. Saved credentials belong
    /// to `keychainProfile`; a private data store passes nil, so what is typed there never outlives the session.
    func resolve(
        _ challenge: URLAuthenticationChallenge,
        keychainProfile: UUID?,
        whenShown: (@escaping @MainActor (NSWindow?) -> Void) -> Void,
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

        whenShown { window in
            guard let window else { return completion(.cancelAuthenticationChallenge, nil) }
            prompt(challenge, storedCredential: storedCredential, offersToRemember: keychainProfile != nil, in: window) { credential, remember in
                guard let credential else {
                    completion(.cancelAuthenticationChallenge, nil)
                    return
                }
                if remember, let keychainProfile { HTTPAuthKeychain.store(credential, for: space, profileId: keychainProfile) }
                completion(.useCredential, credential)
            }
        }
    }

    private func prompt(
        _ challenge: URLAuthenticationChallenge,
        storedCredential: URLCredential?,
        offersToRemember: Bool,
        in window: NSWindow,
        completion: @escaping @MainActor @Sendable (URLCredential?, Bool) -> Void
    ) {
        let space = challenge.protectionSpace
        let realm = space.realm ?? "Restricted Area".localized
        let host = space.host

        let rememberHeight: CGFloat = offersToRemember ? 26 : 0
        let usernameField = NSTextField(frame: NSRect(x: 0, y: 28 + rememberHeight, width: 260, height: 24))
        usernameField.placeholderString = "Username".localized
        usernameField.stringValue = challenge.proposedCredential?.user ?? storedCredential?.user ?? ""

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: rememberHeight, width: 260, height: 24))
        passwordField.placeholderString = "Password".localized

        // Ticked when the credentials being replaced were remembered.
        let rememberBox = NSButton(checkboxWithTitle: "Remember this password".localized, target: nil, action: nil)
        rememberBox.state = storedCredential == nil ? .off : .on
        rememberBox.frame = NSRect(x: 0, y: 0, width: 260, height: 18)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54 + rememberHeight))
        accessory.addSubview(usernameField)
        accessory.addSubview(passwordField)
        if offersToRemember { accessory.addSubview(rememberBox) }

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
                completion(nil, false)
                return
            }
            completion(URLCredential(
                user: usernameField.stringValue,
                password: passwordField.stringValue,
                persistence: .forSession
            ), rememberBox.state == .on)
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }
}
