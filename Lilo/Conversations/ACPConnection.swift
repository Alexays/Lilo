import Foundation
import os

/// A JSON-RPC 2.0 connection to an ACP agent over its standard input and output, one message per line.
/// Lines are read and decoded off the main thread; what the agent sends reaches the main actor in batches,
/// in the order it was written.
final class ACPConnection: @unchecked Sendable {
    struct RPCError: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }

    /// JSON from the agent, handed from the reading queue to the main actor that alone uses it.
    struct Payload: @unchecked Sendable { let value: [String: Any] }

    enum Incoming {
        case request(id: Any, method: String, params: [String: Any])
        case notification(method: String, params: [String: Any])
    }

    private static let logger = Logger(liloCategory: "acp")

    /// Set before `start`, called on the main actor.
    var onMessages: (@MainActor ([Incoming]) -> Void)?
    var onExit: (@MainActor (_ status: Int32, _ errorOutput: String) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Payload, Error>] = [:]
    private var buffer = Data()
    /// The last few kilobytes the agent wrote to standard error, to say why it stopped.
    private var errorTail = Data()

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.receive(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.withLock {
                self.errorTail.append(data)
                if self.errorTail.count > 8192 { self.errorTail.removeFirst(self.errorTail.count - 8192) }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let (waiting, errorText) = self.lock.withLock { () -> ([CheckedContinuation<Payload, Error>], String) in
                defer { self.pending.removeAll() }
                return (Array(self.pending.values), String(decoding: self.errorTail, as: UTF8.self))
            }
            let error = RPCError(code: -32000, message: "The agent stopped")
            waiting.forEach { $0.resume(throwing: error) }
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onExit?(status, errorText) } }
        }
        try process.run()
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Payload, Error>) in
            let id = lock.withLock { () -> Int in
                defer { nextId += 1 }
                pending[nextId] = continuation
                return nextId
            }
            guard process.isRunning, write(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
                if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) {
                    waiting.resume(throwing: RPCError(code: -32000, message: "The agent is not running"))
                }
                return
            }
        }.value
    }

    func notify(_ method: String, _ params: [String: Any]) {
        _ = write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func respond(id: Any, result: [String: Any]) {
        _ = write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respond(id: Any, errorCode: Int, message: String) {
        _ = write(["jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message]])
    }

    /// Ends the agent: its pipes close, so an agent that ignores SIGTERM still stops at its next write.
    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func write(_ message: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            Self.logger.error("write to agent failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func receive(_ data: Data) {
        var messages: [Incoming] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let method = object["method"] as? String {
                    let params = object["params"] as? [String: Any] ?? [:]
                    if let id = object["id"], !(id is NSNull) {
                        messages.append(.request(id: id, method: method, params: params))
                    } else {
                        messages.append(.notification(method: method, params: params))
                    }
                } else if let id = (object["id"] as? NSNumber)?.intValue, let waiting = pending.removeValue(forKey: id) {
                    if let error = object["error"] as? [String: Any] {
                        waiting.resume(throwing: RPCError(code: (error["code"] as? NSNumber)?.intValue ?? -32603,
                                                          message: error["message"] as? String ?? "The agent failed"))
                    } else {
                        waiting.resume(returning: Payload(value: object["result"] as? [String: Any] ?? [:]))
                    }
                }
            }
        }
        guard !messages.isEmpty else { return }
        nonisolated(unsafe) let batch = messages
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onMessages?(batch) }
        }
    }
}
