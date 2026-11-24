import Foundation

/// One running plugin sidecar: one JSON message per write, one per received line.
/// `ProcessPluginTransport` is the stdio/`Process` adapter; TestingSupport's in-process stub
/// is the second implementation the port exists for.
public protocol PluginTransport: AnyObject, Sendable {
    /// Messages the sidecar wrote, one per stdout line, in order. Finishes on exit.
    var lines: AsyncThrowingStream<Data, Error> { get }
    /// Writes one message; the newline is appended by the transport.
    func send(_ data: Data) throws
    /// Terminates the sidecar: SIGTERM, then SIGKILL if it lingers.
    func kill()
    var isRunning: Bool { get }
}
