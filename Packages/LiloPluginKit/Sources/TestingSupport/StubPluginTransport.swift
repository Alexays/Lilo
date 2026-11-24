import Foundation
import PluginCore

/// An in-process `PluginTransport`: sent lines are recorded and routed to `onSend`, which
/// scripts the sidecar's replies by calling `emit`. `kill`/`finish` simulate a stopped sidecar.
public final class StubPluginTransport: PluginTransport, @unchecked Sendable {
    public enum StubError: Error { case stopped }

    public let lines: AsyncThrowingStream<Data, Error>
    public private(set) var sent: [Data] = []
    public private(set) var killed = false
    public var onSend: (@Sendable (StubPluginTransport, Data) -> Void)?

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var running = true

    public init(onSend: (@Sendable (StubPluginTransport, Data) -> Void)? = nil) {
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { streamContinuation = $0 }
        continuation = streamContinuation
        self.onSend = onSend
    }

    public var isRunning: Bool { lock.withLock { running } }

    public func send(_ data: Data) throws {
        try lock.withLock {
            guard running else { throw StubError.stopped }
            sent.append(data)
        }
        onSend?(self, data)
    }

    /// Feeds the session a message as if the sidecar wrote it.
    public func emit(_ message: [String: JSONValue]) {
        let data = (try? JSONSerialization.data(withJSONObject: JSONValue.object(message).anyObject)) ?? Data()
        continuation.yield(data)
    }

    /// The sidecar exited on its own.
    public func exit() {
        lock.withLock { running = false }
        continuation.finish()
    }

    public func kill() {
        lock.withLock {
            killed = true
            running = false
        }
        continuation.finish()
    }
}
