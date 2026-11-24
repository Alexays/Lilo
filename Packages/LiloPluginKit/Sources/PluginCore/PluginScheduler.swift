import Foundation

/// A job the host fires once, `delay` seconds after `schedule`. The `schedule` capability's
/// adapters: `ClockPluginScheduler` in-process, and `CoordinatePluginScheduler` (durable across
/// launches). Re-arming an id replaces its pending fire.
public protocol PluginScheduler: Sendable {
    func schedule(_ jobID: String, after delay: TimeInterval, fire: @escaping @Sendable (String) -> Void)
    func cancel(_ jobID: String)
    /// Hands fires that landed while Lilo was not listening, and later ones, to `fire`.
    /// In-process adapters hold nothing across launches, so the default does nothing.
    func resume(fire: @escaping @Sendable (String) -> Void)
}

public extension PluginScheduler {
    func resume(fire: @escaping @Sendable (String) -> Void) {}
}

/// The in-process fallback: one task per job on the injected clock, so `ManualClock` tests it
/// deterministically and nothing runs while Lilo is quit.
public final class ClockPluginScheduler: PluginScheduler, @unchecked Sendable {
    private let clock: any PluginClock
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(clock: any PluginClock = SystemClock()) {
        self.clock = clock
    }

    public func schedule(_ jobID: String, after delay: TimeInterval, fire: @escaping @Sendable (String) -> Void) {
        let task = Task { [clock] in
            await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            fire(jobID)
        }
        lock.withLock {
            tasks[jobID]?.cancel()
            tasks[jobID] = task
        }
    }

    public func cancel(_ jobID: String) {
        lock.withLock {
            tasks.removeValue(forKey: jobID)?.cancel()
        }
    }
}
