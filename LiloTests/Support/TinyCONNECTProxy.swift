import Foundation
import Network

/// A CONNECT proxy answering every tunneled request itself with `respond(host, request)`: WebKit's tracking
/// prevention ignores loopback hosts, so a test reaches real-looking ones (`example.test`) through it.
final class TinyCONNECTProxy: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(respond: @escaping @Sendable (_ host: String, _ request: String) -> TinyHTTPServer.Response) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let target = (String(bytes: data ?? Data(), encoding: .utf8) ?? "").split(separator: " ").dropFirst().first ?? ""
                let host = String(target.split(separator: ":").first ?? "")
                connection.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        let response = respond(host, String(bytes: data ?? Data(), encoding: .utf8) ?? "")
                        let head = (["HTTP/1.1 \(response.status)"] + response.headers + ["Content-Length: \(response.body.count)", "Connection: close", "", ""])
                            .joined(separator: "\r\n")
                        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
                    }
                })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await value in ready { port = value }
        self.port = port
    }

    deinit { listener.cancel() }
}
