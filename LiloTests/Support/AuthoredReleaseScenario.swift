import Foundation

struct AuthoredReleaseScenario: Decodable {
    struct Fixture: Decodable { let name: String; let html: String }
    struct Tab: Decodable { let id: String; let page: String }
    struct Setting: Decodable { let key: String; let value: String }
    struct Target: Decodable { let surface: String; let selector: String; let text: String }
    enum Value: Decodable {
        case text(String), number(Double), boolean(Bool)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else { self = .text(try value.decode(String.self)) }
        }
        var json: Any {
            switch self { case .text(let value): value; case .number(let value): value; case .boolean(let value): value }
        }
    }
    struct Predicate: Decodable {
        let kind: String
        let target: Target?
        let includes: String?
        let equals: Int?
        let name: String?
        let value: Value?
        let comparison: String?
        let tab: String?
        let key: String?
    }
    struct Step: Decodable {
        let type: String
        let target: Target?
        let from: Target?
        let to: Target?
        let surface: String?
        let text: String?
        let replace: Bool?
        let chord: String?
        let selector: String?
        let modifiers: [String]?
        let button: String?
        let count: Int?
        let durationMs: Int?
        let id: String?
        let predicate: Predicate?
    }
    let id: String
    let fixtures: [Fixture]
    let tabs: [Tab]
    let settings: [Setting]
    let steps: [Step]
}
