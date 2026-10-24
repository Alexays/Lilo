import Foundation
import Network
import XCTest

/// A local HTTP server: `respond` turns each raw request into a status line ("200 OK"), extra header
/// lines and a body.
final class TinyHTTPServer: @unchecked Sendable {
    typealias Response = (status: String, headers: [String], body: Data)
    private let listener: NWListener
    let port: UInt16

    /// Serves `/` as `index` and answers 404 for anything else.
    convenience init(index: String, contentType: String = "text/html", encoding: String.Encoding = .utf8) async throws {
        let body = try XCTUnwrap(index.data(using: encoding))
        try await self.init { request in
            request.hasPrefix("GET / ")
                ? ("200 OK", ["Content-Type: \(contentType)"], body)
                : ("404 Not Found", ["Content-Type: text/html"], Data("missing".utf8))
        }
    }

    init(respond: @escaping @Sendable (String) -> Response) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let response = respond(String(decoding: data ?? Data(), as: UTF8.self))
                let head = (["HTTP/1.1 \(response.status)"] + response.headers + ["Content-Length: \(response.body.count)", "Connection: close", "", ""])
                    .joined(separator: "\r\n")
                connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
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
