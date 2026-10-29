import Foundation
import XCTest

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
/// An async test already runs inside a main-queue block, which cannot nest: there it fails instead of hanging.
@MainActor
func drainMainQueue(timeout: TimeInterval = 5) {
    var drained = false
    DispatchQueue.main.async { drained = true }
    let deadline = Date().addingTimeInterval(timeout)
    while !drained, Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
    if !drained { XCTFail("the main queue never drained: from an async test, await pollUntil instead") }
}
