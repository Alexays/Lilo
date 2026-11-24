import Foundation

/// A JSON value with typed cases: what the plugin protocol carries on the wire, so no `Any`
/// crosses actor boundaries under strict concurrency.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// The Foundation object graph (`NSDictionary`/`NSNumber`/...) `JSONSerialization` exchanges.
    /// Booleans decode from `NSNumber` through CFBoolean's type id, which an NSNumber(1) cannot fake.
    public init(any value: Any?) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// Back to the Foundation object graph, for `JSONSerialization` and bridge payloads.
    public var anyObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map(\.anyObject)
        case .object(let value): return value.mapValues(\.anyObject)
        case .null: return NSNull()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Re-encode and decode through JSONSerialization: for turning a wire object into a Codable.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: anyObject)
        return try JSONDecoder().decode(type, from: data)
    }
}
