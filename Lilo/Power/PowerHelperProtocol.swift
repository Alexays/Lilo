import Foundation
import Security

/// The root helper's XPC interface. Every claim made through a connection lasts as long as it.
@objc protocol PowerHelperProtocol {
    func holdAwake(reply: @escaping (Bool) -> Void)
    /// Gives back everything this connection holds; replies with how many other clients are connected.
    func releaseAll(reply: @escaping (Int) -> Void)
    func setLowPowerMode(_ on: Bool, reply: @escaping (Bool) -> Void)
    /// Stops the processes given as parallel pid and start-time lists; replies with the pids stopped.
    func freeze(pids: [NSNumber], starts: [NSNumber], reply: @escaping ([NSNumber]) -> Void)
    func thaw(reply: @escaping () -> Void)
}

enum PowerHelperIdentity {
    /// A Debug build registers and talks to a daemon of its own, so it never replaces the installed app's.
    static let machService = BuildIdentity.appIdentifier + ".power"
    static let plistName = machService + ".plist"
    static let helperIdentifier = "fr.arouillard.lilo.power-helper"

    /// Requirement for a peer signed by this process's team; nil for an ad-hoc build, which has none.
    static func requirement(forIdentifier identifier: String) -> String? {
        team.map { "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\($0)\"" }
    }

    /// This process's signing team, read once: the signature does not change while it runs.
    private static let team: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()
}
