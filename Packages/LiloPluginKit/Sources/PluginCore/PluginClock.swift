import Foundation

/// Time source for per-call deadlines and scheduling. `ManualClock` in TestingSupport lets
/// tests advance time deterministically instead of waiting real seconds.
public protocol PluginClock: Sendable {
    /// Resumes after `interval` of this clock's time, or early when the calling task is cancelled.
    func sleep(for interval: TimeInterval) async
}

/// The wall clock.
public struct SystemClock: PluginClock {
    public init() {}

    public func sleep(for interval: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
    }
}
