import Foundation

/// What the helper changes on the machine, behind a seam so tests never touch the real settings.
protocol PowerBackend: AnyObject {
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func lowPowerMode() -> Bool?
    func setLowPowerMode(_ on: Bool) -> Bool
    /// Start time in microseconds since 1970, owner, and whether it is already stopped (a ctrl-Z
    /// job); nil once it is gone.
    func process(_ pid: pid_t) -> (start: UInt64, uid: uid_t, stopped: Bool)?
    func send(_ signal: Int32, to pid: pid_t)
    /// Sleeps now if the lid is closed with nothing keeping a closed Mac awake (no external display).
    func sleepIfLidClosed()
}

/// Everything the helper has changed, written before each change so a relaunch can undo it.
struct PowerHelperState: Codable, Equatable {
    struct Frozen: Codable, Hashable {
        let pid: pid_t
        let start: UInt64
    }
    var sleepDisabled = false
    var lowPowerModeBefore: Bool?
    var frozen: [Frozen] = []
}

/// Holds sleep off, Low Power Mode and frozen processes while a session that asked for them lives.
final class PowerHelperService: @unchecked Sendable {
    private struct Claims {
        let pid: pid_t
        var awake = false
        var lowPower = false
        var frozen: [PowerHelperState.Frozen] = []
    }

    private let backend: PowerBackend
    private let stateURL: URL
    private let lock = NSLock()
    private var state = PowerHelperState()
    private var claims: [ObjectIdentifier: Claims] = [:]

    init(backend: PowerBackend, stateURL: URL) {
        self.backend = backend
        self.stateURL = stateURL
        recover()
    }

    func makeSession(uid: uid_t, pid: pid_t) -> PowerHelperSession {
        let session = PowerHelperSession(service: self, uid: uid)
        lock.withLock { claims[ObjectIdentifier(session)] = Claims(pid: pid) }
        return session
    }

    func holdAwake(_ awake: Bool, for session: PowerHelperSession) -> Bool {
        lock.withLock {
            claims[ObjectIdentifier(session)]?.awake = awake
            return applySleep(sleepIfLidClosed: true)
        }
    }

    func setLowPowerMode(_ on: Bool, for session: PowerHelperSession) -> Bool {
        lock.withLock {
            claims[ObjectIdentifier(session)]?.lowPower = on
            return applyLowPower()
        }
    }

    func freeze(_ targets: [PowerHelperState.Frozen], for session: PowerHelperSession) -> [pid_t] {
        lock.withLock {
            // A connected client is never stopped: it could no longer give back what it holds.
            let clients = Set(claims.values.map(\.pid))
            let accepted = targets.filter { target in
                guard !clients.contains(target.pid), let process = backend.process(target.pid) else { return false }
                // A job the user stopped stays theirs: thawing it would resume it behind their back.
                return process.start == target.start && process.uid == session.uid && process.uid != 0 && !process.stopped
                    && !state.frozen.contains(target)
            }
            state.frozen += accepted
            // Nothing is stopped that a relaunch could not find to resume.
            guard persist() else {
                state.frozen.removeLast(accepted.count)
                persist()
                return []
            }
            claims[ObjectIdentifier(session)]?.frozen += accepted
            for target in accepted { backend.send(SIGSTOP, to: target.pid) }
            return accepted.map(\.pid)
        }
    }

    /// Undoes this session's claims but keeps it connected; returns how many other sessions remain.
    func releaseAll(for session: PowerHelperSession) -> Int {
        lock.withLock {
            let id = ObjectIdentifier(session)
            thaw(claims[id]?.frozen ?? [])
            claims[id]?.frozen = []
            claims[id]?.awake = false
            claims[id]?.lowPower = false
            _ = applyLowPower()
            _ = applySleep(sleepIfLidClosed: true)
            return claims.count - 1
        }
    }

    /// The helper is being stopped (shutdown, restart, unregister): every claim is undone first.
    func endAll() {
        lock.withLock {
            thaw(claims.values.flatMap(\.frozen))
            claims.removeAll()
            _ = applyLowPower()
            _ = applySleep(sleepIfLidClosed: false)
        }
    }

    func thaw(for session: PowerHelperSession) {
        lock.withLock {
            thaw(claims[ObjectIdentifier(session)]?.frozen ?? [])
            claims[ObjectIdentifier(session)]?.frozen = []
        }
    }

    func end(_ session: PowerHelperSession) {
        lock.withLock {
            guard let ended = claims.removeValue(forKey: ObjectIdentifier(session)) else { return }
            thaw(ended.frozen)
            _ = applyLowPower()
            _ = applySleep(sleepIfLidClosed: true)
        }
    }

    // Called with the lock held. Giving sleep back with the lid closed does not sleep by itself
    // until the next idle timeout, so a released closed Mac is put to sleep right away; never
    // while the helper itself is stopping (shutdown, restart).
    private func applySleep(sleepIfLidClosed: Bool) -> Bool {
        let wanted = claims.values.contains { $0.awake }
        guard wanted != state.sleepDisabled else { return true }
        if wanted {
            state.sleepDisabled = true
            // Sleep stays on unless a relaunch could find that it must turn it back on.
            guard persist(), backend.setSleepDisabled(true) else {
                state.sleepDisabled = false
                persist()
                return false
            }
            return true
        }
        guard backend.setSleepDisabled(false) else { return false }
        state.sleepDisabled = false
        persist()
        if sleepIfLidClosed { backend.sleepIfLidClosed() }
        return true
    }

    // Called with the lock held. The mode the user had on is never switched off.
    private func applyLowPower() -> Bool {
        let wanted = claims.values.contains { $0.lowPower }
        if wanted, state.lowPowerModeBefore == nil {
            guard let before = backend.lowPowerMode() else { return false }
            state.lowPowerModeBefore = before
            // A failed switch leaves nothing recorded, so the next request tries again.
            guard persist(), before || backend.setLowPowerMode(true) else {
                state.lowPowerModeBefore = nil
                persist()
                return false
            }
            return true
        }
        if !wanted, let before = state.lowPowerModeBefore {
            guard before || backend.setLowPowerMode(false) else { return false }
            state.lowPowerModeBefore = nil
            persist()
        }
        return true
    }

    // Called with the lock held.
    private func thaw(_ targets: [PowerHelperState.Frozen]) {
        guard !targets.isEmpty else { return }
        for target in targets where backend.process(target.pid)?.start == target.start {
            backend.send(SIGCONT, to: target.pid)
        }
        state.frozen.removeAll { targets.contains($0) }
        persist()
    }

    private func recover() {
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(PowerHelperState.self, from: data) else { return }
        lock.withLock {
            state = saved
            thaw(saved.frozen)
            if saved.sleepDisabled, backend.setSleepDisabled(false) { state.sleepDisabled = false }
            if let before = saved.lowPowerModeBefore, before || backend.setLowPowerMode(false) { state.lowPowerModeBefore = nil }
            persist()
        }
    }

    /// Whether the state reached the disk.
    @discardableResult
    private func persist() -> Bool {
        let directory = stateURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            return true
        } catch {
            return false
        }
    }
}

/// One client connection: what it asked for is undone by `end()`, which the connection's
/// invalidation calls whatever ended it.
final class PowerHelperSession: NSObject, PowerHelperProtocol, @unchecked Sendable {
    private let service: PowerHelperService
    let uid: uid_t

    init(service: PowerHelperService, uid: uid_t) {
        self.service = service
        self.uid = uid
    }

    func holdAwake(reply: @escaping (Bool) -> Void) { reply(service.holdAwake(true, for: self)) }
    func releaseAll(reply: @escaping (Int) -> Void) { reply(service.releaseAll(for: self)) }
    func setLowPowerMode(_ on: Bool, reply: @escaping (Bool) -> Void) { reply(service.setLowPowerMode(on, for: self)) }

    func freeze(pids: [NSNumber], starts: [NSNumber], reply: @escaping ([NSNumber]) -> Void) {
        let targets = zip(pids, starts).map { PowerHelperState.Frozen(pid: $0.int32Value, start: $1.uint64Value) }
        reply(service.freeze(targets, for: self).map { NSNumber(value: $0) })
    }

    func thaw(reply: @escaping () -> Void) { service.thaw(for: self); reply() }
    func end() { service.end(self) }
}
