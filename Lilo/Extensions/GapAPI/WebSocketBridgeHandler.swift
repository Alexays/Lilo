import Foundation

/// URLSession-backed WebSockets for extension workers: WebKit's worker WebSocket constructor hangs the main thread it runs on
/// (WEBKIT-GAPS.md, gap 33). A socket closes with its extension and with the worker that opened it.
@MainActor
final class WebSocketBridgeHandler: NSObject, GapHandler, URLSessionWebSocketDelegate {
    let gapActions: Set<String> = ["webSocket.connect", "webSocket.send", "webSocket.close"]

    private struct Socket {
        let task: URLSessionWebSocketTask
        let extensionId: String
        weak var registry: ProfileExtensionRegistry?
        /// The worker that opened it: a socket outlives no worker, as in Chrome.
        let worker: String?
    }

    private var sockets: [Int: Socket] = [:]
    private var nextId = 0
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    nonisolated(unsafe) private var unloadObserver: Any?

    override init() {
        super.init()
        unloadObserver = NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard let extensionId = note.userInfo?["extensionId"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, socket) in self.sockets where socket.extensionId == extensionId { self.drop(id, code: .goingAway) }
            }
        }
    }

    deinit {
        unloadObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        switch call.action {
        case "webSocket.connect":
            guard let context = call.context,
                  let url = call.string("url").flatMap(URL.init(string:)), ["ws", "wss"].contains(url.scheme) else {
                return BridgeError("Invalid WebSocket url")
            }
            var request = URLRequest(url: url)
            request.setValue("\(context.baseURL.scheme ?? "")://\(context.baseURL.host ?? "")", forHTTPHeaderField: "Origin")
            let protocols = call.payload["protocols"] as? [String] ?? []
            if !protocols.isEmpty { request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
            let task = session.webSocketTask(with: request)
            nextId += 1
            sockets[nextId] = Socket(task: task, extensionId: call.extensionId, registry: call.registry,
                                     worker: call.registry.gapEvents.workerInstance(of: call.extensionId))
            task.taskDescription = String(nextId)
            task.resume()
            receive(nextId)
            return nextId

        case "webSocket.send":
            guard let socket = call.int("id").flatMap({ sockets[$0] }), owns(socket, call) else { return BridgeError("WebSocket is closed") }
            let message: URLSessionWebSocketTask.Message
            if let text = call.string("text") {
                message = .string(text)
            } else if let data = call.string("binary").flatMap({ Data(base64Encoded: $0) }) {
                message = .data(data)
            } else {
                return BridgeError("Invalid WebSocket message")
            }
            try? await socket.task.send(message)
            return nil

        case "webSocket.close":
            guard let id = call.int("id"), let socket = sockets[id], owns(socket, call) else { return nil }
            let code = URLSessionWebSocketTask.CloseCode(rawValue: call.int("code") ?? 1000) ?? .normalClosure
            socket.task.cancel(with: code, reason: call.string("reason").map { Data($0.utf8) })
            return nil

        default:
            return nil
        }
    }

    /// Socket ids are counted across extensions and profiles: only the one that opened a socket uses it.
    private func owns(_ socket: Socket, _ call: GapCall) -> Bool {
        socket.extensionId == call.extensionId && socket.registry === call.registry
    }

    private func receive(_ id: Int) {
        sockets[id]?.task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    self.emit(id, ["type": "message", "text": text])
                    self.receive(id)
                case .success(.data(let data)):
                    self.emit(id, ["type": "message", "binary": data.base64EncodedString()])
                    self.receive(id)
                case .success:
                    self.receive(id)
                case .failure:
                    // The close delegate call or didCompleteWithError reports why.
                    break
                }
            }
        }
    }

    /// Sends the event to the worker that opened the socket; one that stopped or restarted closes it.
    private func emit(_ id: Int, _ event: [String: Any]) {
        guard let socket = sockets[id], let registry = socket.registry else { return }
        guard registry.gapEvents.workerInstance(of: socket.extensionId) == socket.worker else {
            drop(id, code: .goingAway)
            return
        }
        registry.gapEvents.emit("webSocket", "onEvent", args: [event.merging(["id": id]) { $1 }], to: [socket.extensionId], wakes: false)
    }

    private func drop(_ id: Int, code: URLSessionWebSocketTask.CloseCode) {
        sockets.removeValue(forKey: id)?.task.cancel(with: code, reason: nil)
    }

    private func id(of task: URLSessionTask) -> Int? {
        task.taskDescription.flatMap(Int.init)
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            guard let id = id(of: webSocketTask) else { return }
            emit(id, ["type": "open", "protocol": `protocol` ?? ""])
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated {
            guard let id = id(of: webSocketTask) else { return }
            emit(id, ["type": "close", "code": closeCode.rawValue, "reason": reason.flatMap { String(bytes: $0, encoding: .utf8) } ?? "", "wasClean": true])
            sockets[id] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            // A socket that closed cleanly already reported it.
            guard let id = id(of: task), sockets[id] != nil else { return }
            if error != nil { emit(id, ["type": "error"]) }
            emit(id, ["type": "close", "code": 1006, "reason": "", "wasClean": false])
            sockets[id] = nil
        }
    }
}
