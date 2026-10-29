import AppKit
import SecurityInterface

/// Resolves TLS client-certificate challenges as Safari does: the keychain identities the server accepts, chosen in
/// Security's identity panel, and remembered per host for the session.
@MainActor
enum ClientCertificateChallengeHandler {
    typealias Completion = @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    private static var chosen: [String: SecIdentity] = [:]
    /// The panel is shared: a page's other requests to a host already asking wait for that one answer.
    private static var waiting: [String: [Completion]] = [:]

    /// `completion` runs exactly once. Without an identity the server accepts, the challenge goes on without one.
    static func resolve(_ challenge: URLAuthenticationChallenge, in window: NSWindow?, completion: @escaping Completion) {
        let host = challenge.protectionSpace.host
        if challenge.previousFailureCount == 0, let identity = chosen[host] {
            return completion(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        }
        if waiting[host] != nil { return waiting[host, default: []].append(completion) }
        chosen[host] = nil

        var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
        if let issuers = challenge.protectionSpace.distinguishedNames, !issuers.isEmpty { query[kSecMatchIssuers] = issuers }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity], !identities.isEmpty,
              let panel = SFChooseIdentityPanel.shared() else { return completion(.performDefaultHandling, nil) }

        waiting[host] = [completion]
        let message = String(format: "%@ asks for a certificate to identify you.".localized, host)
        let finish: @MainActor (Bool) -> Void = { chose in
            let identity = chose ? panel.identity()?.takeUnretainedValue() : nil
            if let identity { chosen[host] = identity }
            let credential = identity.map { URLCredential(identity: $0, certificates: nil, persistence: .forSession) }
            for completion in waiting.removeValue(forKey: host) ?? [] {
                completion(credential == nil ? .cancelAuthenticationChallenge : .useCredential, credential)
            }
        }
        guard let window else { return finish(panel.runModal(forIdentities: identities, message: message) == NSApplication.ModalResponse.OK.rawValue) }
        let end = SheetEnd(finish)
        panel.beginSheet(
            for: window, modalDelegate: end, didEnd: #selector(SheetEnd.panelDidEnd(_:returnCode:contextInfo:)),
            contextInfo: Unmanaged.passRetained(end).toOpaque(), identities: identities, message: message
        )
    }

    /// The panel's sheet reports through a selector, on the main thread; the context holds this target until it does.
    @MainActor
    private final class SheetEnd: NSObject {
        let finish: @MainActor (Bool) -> Void
        init(_ finish: @escaping @MainActor (Bool) -> Void) { self.finish = finish }

        @objc func panelDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer) {
            Unmanaged<SheetEnd>.fromOpaque(contextInfo).release()
            finish(returnCode == NSApplication.ModalResponse.OK.rawValue)
        }
    }
}
