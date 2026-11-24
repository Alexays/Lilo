import Foundation

/// A `PluginTransport` over the sidecar's stdio: `Process` plus pipes, one JSON message per
/// line — the same framing `ACPConnection` uses. Foundation only.
public final class ProcessPluginTransport: PluginTransport, @unchecked Sendable {
    public let lines: AsyncThrowingStream<Data, Error>
    /// The last kilobytes the sidecar wrote to stderr, to say why it stopped.
    public var errorText: String { lock.withLock { String(bytes: errorTail, encoding: .utf8) ?? "" } }

    private let streamContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()

    public init(executable: URL, arguments: [String] = [], environment: [String: String]? = nil, directory: URL) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { continuation = $0 }
        streamContinuation = continuation
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
    }

    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                streamContinuation.finish()
                return
            }
            receive(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            lock.withLock {
                errorTail.append(data)
                if errorTail.count > 8192 { errorTail.removeFirst(errorTail.count - 8192) }
            }
        }
        try process.run()
    }

    public enum TransportError: Error { case notRunning }

    public func send(_ data: Data) throws {
        guard process.isRunning else { throw TransportError.notRunning }
        var line = data
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    /// Ends the sidecar: SIGTERM, then SIGKILL when it ignores it. Its pipes close, so a
    /// process that ignores both signals still stops at its next write.
    public func kill() {
        output.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
            }
        }
        try? input.fileHandleForWriting.close()
        streamContinuation.finish()
    }

    deinit {
        kill()
    }

    /// Splits incoming bytes at newlines, scanning only the new bytes (see ACPConnection).
    private func receive(_ data: Data) {
        lock.withLock {
            let scanned = buffer.count
            buffer.append(data)
            var lineStart = buffer.startIndex
            var searchFrom = lineStart + scanned
            defer { if lineStart > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<lineStart) } }
            while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
                let line = Data(buffer[lineStart..<newline])
                lineStart = newline + 1
                searchFrom = lineStart
                if !line.isEmpty { streamContinuation.yield(line) }
            }
        }
    }
}
