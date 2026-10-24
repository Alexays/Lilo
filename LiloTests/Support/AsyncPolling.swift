import Foundation

/// Polls with real suspensions (not just `Task.yield()`) so work deferred through
/// `DispatchQueue.main.async` or WebKit IPC gets a chance to land. Returns whether `condition`
/// held before the deadline; callers decide whether a timeout is a failure.
@MainActor
@discardableResult
func pollUntil(timeout: TimeInterval = 15, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// Runs the main run loop until every block queued on the main queue so far has run. A short
/// `RunLoop.run(until:)` can return before that: under load one pass services another port instead.
@MainActor
func drainMainQueue() {
    DispatchQueue.main.async { CFRunLoopStop(CFRunLoopGetMain()) }
    CFRunLoopRun()
}
