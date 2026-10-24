import Foundation

/// Thread-safe leading-edge throttle for progress callbacks on non-main queues. Call `pass(interval:)` before hopping to the main actor,
/// so the per-chunk flood is gated at the source instead of after paying the Task hop.
final class ProgressEmitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmit = Date.distantPast

    func pass(interval: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= interval else { return false }
        lastEmit = now
        return true
    }
}
