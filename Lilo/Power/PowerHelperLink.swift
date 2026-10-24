import Foundation
import OSLog
import ServiceManagement

/// An open connection to the root helper: closing it undoes everything asked through it.
@MainActor
protocol PowerHelperLink: AnyObject {
    var helper: PowerHelperProtocol { get }
    /// The helper went away and undid what this link held: `true` when the connection is invalid
    /// for good (not approved, signature refused), `false` when the helper crashed and can be reached again.
    var onLost: ((Bool) -> Void)? { get set }
    func close()
}

@MainActor
final class XPCPowerHelperLink: PowerHelperLink {
    private nonisolated static let logger = Logger(liloCategory: "PowerHelper")
    private let connection: NSXPCConnection
    let helper: PowerHelperProtocol
    var onLost: ((Bool) -> Void)?

    /// Nil for an ad-hoc build: without a team, the helper's signature cannot be checked.
    init?() {
        guard let requirement = PowerHelperIdentity.requirement(forIdentifier: PowerHelperIdentity.helperIdentifier) else { return nil }
        connection = NSXPCConnection(machServiceName: PowerHelperIdentity.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Self.logger.error("power helper call failed: \(error.localizedDescription, privacy: .public)")
        }) as? PowerHelperProtocol else { return nil }
        helper = proxy
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLost?(false) } }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLost?(true) } }
        }
        connection.resume()
    }

    func close() {
        connection.invalidate()
    }
}

/// Installs and removes the helper; macOS asks the user to approve it once in System Settings.
@MainActor
protocol PowerHelperInstaller: AnyObject {
    var status: String { get }
    func register()
    func unregister()
}

@MainActor
final class SMAppServiceInstaller: PowerHelperInstaller {
    private nonisolated static let logger = Logger(liloCategory: "PowerHelper")
    private let service = SMAppService.daemon(plistName: PowerHelperIdentity.plistName)

    var status: String {
        guard PowerHelperIdentity.requirement(forIdentifier: PowerHelperIdentity.helperIdentifier) != nil else { return "unsigned" }
        switch service.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        default: return "notRegistered"
        }
    }

    func register() {
        do { try service.register() } catch {
            Self.logger.error("power helper register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func unregister() {
        service.unregister { error in
            if let error { Self.logger.error("power helper unregister failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
