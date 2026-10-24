import Foundation

/// Accepts client connections for the helper; a session ends with its connection, whatever ended
/// it. `open` and `idleExit` are only touched on the main queue.
final class PowerHelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service: PowerHelperService
    private let onIdle: @Sendable () -> Void
    private var open = Set<ObjectIdentifier>()
    private var idleExit: DispatchWorkItem?

    /// `onIdle` runs once no connection has been open for 30 s; launchd relaunches on demand.
    init(service: PowerHelperService, onIdle: @escaping @Sendable () -> Void) {
        self.service = service
        self.onIdle = onIdle
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = service.makeSession(uid: connection.effectiveUserIdentifier, pid: connection.processIdentifier)
        let id = ObjectIdentifier(session)
        connection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.exportedObject = session
        // Interruption and invalidation may both fire: ending twice is a no-op.
        let ended = { DispatchQueue.main.async { session.end(); self.closed(id) } }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        DispatchQueue.main.async { self.open.insert(id); self.idleExit?.cancel() }
        connection.resume()
        return true
    }

    func armIdleExit() {
        let work = DispatchWorkItem(block: onIdle)
        idleExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func closed(_ id: ObjectIdentifier) {
        guard open.remove(id) != nil, open.isEmpty else { return }
        armIdleExit()
    }
}
