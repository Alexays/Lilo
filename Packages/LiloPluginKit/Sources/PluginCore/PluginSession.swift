import Foundation

/// An error a plugin can answer a host-ward request with; serialized as a JSON-RPC `error`.
public struct PluginRequestError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// A plugin calling a host API it was not granted gets this back.
    public static let capabilityNotGranted = PluginRequestError(code: -32001, message: "Capability not granted")
    /// Anything else the host does not implement.
    public static let methodNotFound = PluginRequestError(code: -32601, message: "Method not found")
}

public enum PluginSessionError: Error, Equatable {
    /// The spawn closure or `Process` launch failed.
    case spawnFailed(String)
    /// The sidecar's stream ended or it was killed.
    case transportLost
    /// A call passed its deadline; the sidecar was killed.
    case deadlineExceeded
    /// The plugin answered `initialize` with a protocol version the host cannot speak.
    case protocolMismatch
    /// The plugin answered a call with a JSON-RPC `error` object.
    case rpc(code: Int, message: String)
}

/// What the plugin's `initialize` reply (the `ready` payload) declared.
public struct PluginReady: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let tools: [PluginManifest.Tool]
}

/// One enabled plugin's sidecar lifecycle and JSON-RPC channel.
///
/// ndjson JSON-RPC 2.0 over the transport. `start` spawns lazily and handshakes once
/// (`initialize` → the plugin's `ready` reply carrying its tools). A call carries a deadline
/// (default 10 s): missing it kills the sidecar, which is then treated as "not running" —
/// never an error state — and the next call spawns a fresh one and re-handshakes.
public actor PluginSession {
    public static let defaultDeadline: TimeInterval = 10
    public static let protocolVersion = 1

    /// Notifications the plugin sends (`log`, ...): `(method, params)`.
    public var onNotification: (@Sendable (String, JSONValue) -> Void)?
    /// Requests the plugin sends host-ward. Unset means every method answers `methodNotFound`.
    public var onRequest: (@Sendable (String, JSONValue) async -> Result<JSONValue, PluginRequestError>)?
    /// The sidecar stopped or was killed (deadline miss, idle exit, `stop`).
    public var onExit: (@Sendable () -> Void)?

    /// The `ready` payload of the current sidecar, nil once it stops.
    public private(set) var ready: PluginReady?

    private let spawn: @Sendable () async throws -> any PluginTransport
    private let clock: any PluginClock
    private let initializeParams: @Sendable () async -> [String: JSONValue]
    private var transport: (any PluginTransport)?
    private var reader: Task<Void, Never>?
    private var starting: Task<PluginReady, Error>?
    private var nextID = 1

    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]

    public init(
        spawn: @escaping @Sendable () async throws -> any PluginTransport,
        clock: any PluginClock = SystemClock(),
        initializeParams: @escaping @Sendable () async -> [String: JSONValue] = { [:] }
    ) {
        self.spawn = spawn
        self.clock = clock
        self.initializeParams = initializeParams
    }

    /// A session over a `ProcessPluginTransport` for the manifest's `entry`, run with the
    /// plugin folder as its working directory.
    public init(
        manifest: PluginManifest,
        pluginRoot: URL,
        clock: any PluginClock = SystemClock(),
        initializeParams: @escaping @Sendable () async -> [String: JSONValue] = { [:] }
    ) {
        self.init(spawn: {
            let transport = ProcessPluginTransport(
                executable: pluginRoot.appendingPathComponent(manifest.entry), directory: pluginRoot
            )
            try transport.start()
            return transport
        }, clock: clock, initializeParams: initializeParams)
    }

    public var isRunning: Bool { transport?.isRunning ?? false }

    /// Spawns and handshakes unless already up; every caller shares the one in-flight start.
    @discardableResult
    public func start() async throws -> PluginReady {
        if let ready, transport?.isRunning == true { return ready }
        if let starting { return try await starting.value }
        let task = Task<PluginReady, Error> {
            let transport: any PluginTransport
            do {
                transport = try await spawn()
            } catch {
                throw PluginSessionError.spawnFailed("\(error)")
            }
            attach(transport)
            do {
                return try await handshake(on: transport)
            } catch {
                drop(transport)
                throw error
            }
        }
        starting = task
        defer { starting = nil }
        let ready = try await task.value
        self.ready = ready
        return ready
    }

    /// A host→plugin call with its deadline; (re)spawns the sidecar on demand.
    @discardableResult
    public func request(
        _ method: String, params: [String: JSONValue] = [:], deadline: TimeInterval = defaultDeadline
    ) async throws -> JSONValue {
        _ = try await start()
        guard let transport else { throw PluginSessionError.transportLost }
        return try await send(on: transport, method: method, params: params, deadline: deadline)
    }

    /// A host→plugin notification; a stopped sidecar is not woken for it.
    public func notify(_ method: String, params: [String: JSONValue] = [:]) {
        guard let transport, transport.isRunning else { return }
        try? transport.send(Self.encode([
            "jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)
        ]))
    }

    /// Ends the sidecar; the plugin stays enabled and respawns on the next call.
    public func stop() {
        guard let transport else { return }
        self.transport = nil
        ready = nil
        reader?.cancel()
        reader = nil
        failAll(PluginSessionError.transportLost)
        transport.kill()
        onExit?()
    }

    // MARK: - Handshake

    private func handshake(on transport: any PluginTransport) async throws -> PluginReady {
        var params = await initializeParams()
        params["protocolVersion"] = .number(Double(Self.protocolVersion))
        let result = try await send(on: transport, method: "initialize", params: params, deadline: Self.defaultDeadline)
        guard case .object(let object) = result, case .number(let version) = object["protocolVersion"],
              Int(version) == Self.protocolVersion else { throw PluginSessionError.protocolMismatch }
        // The manifest already declares the tools; `ready`'s list is best-effort.
        let tools = (try? result.decode(PluginReady.self))?.tools ?? []
        return PluginReady(protocolVersion: Int(version), tools: tools)
    }

    // MARK: - Wire

    private func send(
        on transport: any PluginTransport, method: String, params: [String: JSONValue], deadline: TimeInterval
    ) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let timeout = Task {
            await clock.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            deadlineHit(id)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(continuation: continuation, timeout: timeout)
            do {
                try transport.send(Self.encode([
                    "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                    "method": .string(method), "params": .object(params)
                ]))
            } catch {
                timeout.cancel()
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func attach(_ transport: any PluginTransport) {
        self.transport = transport
        reader = Task {
            do {
                for try await line in transport.lines { receive(line, from: transport) }
            } catch {}
            transportEnded(transport)
        }
    }

    private func receive(_ line: Data, from transport: any PluginTransport) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let method = object["method"] as? String {
            let params = JSONValue(any: object["params"])
            if let id = object["id"], !(id is NSNull) {
                let requestID = JSONValue(any: id)
                Task { await answer(requestID, method: method, params: params, on: transport) }
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let idNumber = object["id"] as? NSNumber,
              let pending = pending.removeValue(forKey: idNumber.intValue) else { return }
        pending.timeout.cancel()
        if let error = object["error"] as? [String: Any] {
            pending.continuation.resume(throwing: PluginSessionError.rpc(
                code: (error["code"] as? NSNumber)?.intValue ?? -32603,
                message: error["message"] as? String ?? "The plugin call failed"
            ))
        } else {
            pending.continuation.resume(returning: JSONValue(any: object["result"]))
        }
    }

    private func answer(_ id: JSONValue, method: String, params: JSONValue, on transport: any PluginTransport) async {
        let result = await onRequest?(method, params) ?? .failure(.methodNotFound)
        var response: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        switch result {
        case .success(let value):
            response["result"] = value
        case .failure(let error):
            response["error"] = .object(["code": .number(Double(error.code)), "message": .string(error.message)])
        }
        try? transport.send(Self.encode(response))
    }

    // MARK: - Death

    /// A call missed its deadline: the sidecar is wedged — kill it and fail every call on it.
    private func deadlineHit(_ id: Int) {
        guard pending.keys.contains(id), let transport else { return }
        self.transport = nil
        ready = nil
        reader?.cancel()
        reader = nil
        failAll(PluginSessionError.deadlineExceeded)
        transport.kill()
        onExit?()
    }

    /// The transport's stream finished: the sidecar exited (idle or crash).
    private func transportEnded(_ transport: any PluginTransport) {
        guard self.transport === transport else { return }
        self.transport = nil
        ready = nil
        reader = nil
        failAll(PluginSessionError.transportLost)
        onExit?()
    }

    /// A handshake that never finished leaves no running sidecar behind.
    private func drop(_ transport: any PluginTransport) {
        guard self.transport === transport else { return }
        self.transport = nil
        reader?.cancel()
        reader = nil
        failAll(PluginSessionError.transportLost)
        transport.kill()
    }

    private func failAll(_ error: PluginSessionError) {
        let waiting = pending
        pending.removeAll()
        for (_, call) in waiting {
            call.timeout.cancel()
            call.continuation.resume(throwing: error)
        }
    }

    private static func encode(_ message: [String: JSONValue]) -> Data {
        (try? JSONSerialization.data(withJSONObject: JSONValue.object(message).anyObject)) ?? Data()
    }
}
