import Foundation
import GRDB

/// A Profile provides full session isolation: separate cookies, cache, storage, and database.
struct Profile: Sendable, Identifiable {
    /// The Space color presets (SpaceEditor.svelte): profile avatars take the same pastels.
    static let palette = [
        "#92a8ff", "#b39df4", "#f1a7a5", "#f4bb8c", "#e8d98f", "#9bd3b4",
        "#8fd5cf", "#9ac7eb", "#c3a5ea", "#f0a8c8", "#a7bcc7", "#c8ab98"
    ]

    let id: UUID
    var name: String
    var isDefault: Bool
    var color: String
    var createdAt = Date()
    var modifiedAt = Date()

    init(id: UUID = UUID(), name: String = "Default", isDefault: Bool = false, color: String = Profile.palette[0]) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.color = color
    }

    var bridgeData: [String: Any] {
        ["id": id.uuidString, "name": name, "isDefault": isDefault, "color": color]
    }
}

// MARK: - GRDB

extension Profile: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profiles"

    // The id column persists as TEXT so filters like `Column("id") == id.uuidString` keep matching.
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}
