import Foundation
import PluginCore

/// A clock tests advance by hand: `advance` wakes every sleeper whose deadline passed.
/// Cancellation removes the sleeper, matching `Task.sleep`.
public final class ManualClock: PluginClock, @unchecked Sendable {
    private var waiters: [Int: (at: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextID = 0
    private let lock = NSLock()
    public private(set) var now: TimeInterval = 0

    public init() {}

    /// Sleepers still armed: a test waits on this instead of sleeping real time.
    public var armedCount: Int { lock.withLock { waiters.count } }

    public func sleep(for interval: TimeInterval) async {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { waiters[id] = (now + interval, continuation) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id)?.continuation.resume() }
        }
    }

    /// Moves time forward, resuming the sleepers whose deadline passed.
    public func advance(by delta: TimeInterval) {
        let due: [CheckedContinuation<Void, Never>] = lock.withLock {
            now += delta
            let expired = waiters.filter { $0.value.at <= now }
            for id in expired.keys { waiters.removeValue(forKey: id) }
            return expired.map(\.value.continuation)
        }
        due.forEach { $0.resume() }
    }
}
