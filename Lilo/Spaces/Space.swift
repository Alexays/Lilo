import Foundation
import GRDB

/// A Space groups tabs together within a Profile.
struct Space: Sendable, Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var color: String
    var profileId: UUID
    var isPrivate: Bool
    var activeTabId: UUID?
    var sortOrder: Int
    /// Idle hours before a top-level unpinned tab is archived; 0 never archives.
    var archiveAfterHours = 12
    /// Where the chrome color comes from; `color` stays the base the other modes light or fall back to.
    var colorMode = Space.fixedColorMode
    /// What the chrome is made of: a solid fill, see-through glass, or grain over the color.
    var material = Space.solidMaterial
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(), name: String = "New Space", icon: String = "🌐", color: String = "#5865f2",
        profileId: UUID, isPrivate: Bool = false, activeTabId: UUID? = nil, sortOrder: Int = 0
    ) {
        self.id = id; self.name = name; self.icon = icon; self.color = color
        self.profileId = profileId; self.isPrivate = isPrivate; self.activeTabId = activeTabId; self.sortOrder = sortOrder
        createdAt = Date(); modifiedAt = Date()
    }

    static let fixedColorMode = "fixed"
    static let colorModes: Set<String> = [fixedColorMode, "time", "page", "wallpaper"]
    static let solidMaterial = "solid"
    static let materials: Set<String> = [solidMaterial, "glass", "grain"]

    /// Serializable dictionary for bridge communication.
    var bridgeData: [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "icon": icon,
            "color": color,
            "profileId": profileId.uuidString,
            "isPrivate": isPrivate,
            "sortOrder": sortOrder,
            "archiveAfterHours": archiveAfterHours,
            "colorMode": colorMode,
            "material": material
        ]
    }
}

// MARK: - GRDB

extension Space: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "spaces"

    enum Columns: String, ColumnExpression {
        case id, name, icon, color, profileId, isPrivate, activeTabId, sortOrder, createdAt, modifiedAt
    }

    // UUID columns persist as TEXT so GRDB column filters like
    // `Columns.profileId == id.uuidString` keep matching.
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}
