import Foundation

/// A message sent from the Svelte chrome to Swift.
struct BridgeMessage {
    let action: String
    let payload: [String: Any]

    init?(dictionary: [String: Any]) {
        guard let action = dictionary["action"] as? String else { return nil }
        self.action = action
        self.payload = dictionary["payload"] as? [String: Any] ?? [:]
    }
}

/// Typed reads of a JSON payload, shared by chrome UI messages and extension gap calls.
protocol PayloadReading {
    var payload: [String: Any] { get }
}

extension BridgeMessage: PayloadReading {}

extension PayloadReading {
    func string(_ key: String) -> String? {
        payload[key] as? String
    }

    func string(_ key: String, default defaultValue: String) -> String {
        string(key) ?? defaultValue
    }

    private func number(_ key: String) -> NSNumber? {
        payload[key] as? NSNumber
    }

    func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        (payload[key] as? Bool) ?? number(key)?.boolValue ?? defaultValue
    }

    func int(_ key: String) -> Int? {
        (payload[key] as? Int) ?? number(key)?.intValue
    }

    func double(_ key: String) -> Double? {
        (payload[key] as? Double) ?? number(key)?.doubleValue
    }

    func cgFloat(_ key: String) -> CGFloat? {
        double(key).map { CGFloat($0) }
    }

    func uuid(_ key: String) -> UUID? {
        guard let value = string(key) else { return nil }
        return UUID(uuidString: value)
    }

    func url(_ key: String) -> URL? {
        guard let value = string(key) else { return nil }
        return URL(string: value)
    }
}

/// Sentinel a `GapHandler` returns to fail; `GapBridgeRouter` turns it into the JS callback's `error` argument. A type rather than an
/// `error` key, so a success payload that carries an `error` field is never mistaken for a failure.
struct BridgeError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Protocol for handling a specific category of bridge messages.
@MainActor
protocol BridgeHandler {
    /// The exact actions this handler responds to.
    var handledActions: Set<String> { get }

    /// Handle an incoming bridge message. Return a response payload if needed.
    func handle(message: BridgeMessage) async -> Any?
}
