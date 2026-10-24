import Foundation
@testable import Lilo

/// Records the events a router sends to the chrome, in wire order.
@MainActor
final class BridgeEventRecorder {
    private(set) var events: [(name: String, data: [String: Any])] = []

    init(_ router: BridgeRouter) {
        router.javaScriptSink = { [weak self] _, arguments, completion in
            let messages = arguments["messages"] as? [[String: Any]] ?? (arguments["message"] as? [String: Any]).map { [$0] } ?? []
            for message in messages {
                guard let name = message["event"] as? String else { continue }
                self?.events.append((name, message))
            }
            completion()
        }
    }

    /// The data of every `name` event sent so far, once the router's queued sends delivered one, or after a second.
    func data(_ name: String) -> [[String: Any]] {
        // The router flushes 16 ms after a send, later on a loaded machine.
        let end = Date().addingTimeInterval(1)
        while Date() < end, !events.contains(where: { $0.name == name }) { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return events.filter { $0.name == name }.map(\.data)
    }
}
