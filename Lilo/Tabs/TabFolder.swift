import Foundation

struct TabFolder: Sendable, Identifiable, Equatable {
    let id: UUID
    var spaceId: UUID
    var name: String
    var color: String
    var isCollapsed: Bool
    /// Set on a split view: how its tabs tile the content area.
    var splitLayout: SplitLayout?
    var lock: FolderLock?
    /// Runtime only, like `StoredFolder.isUnlocked`.
    var isUnlocked: Bool

    var isSplit: Bool { splitLayout != nil }
    var isLocked: Bool { lock != nil && !isUnlocked }

    init(
        id: UUID = UUID(),
        spaceId: UUID,
        name: String = "New Folder",
        color: String = "#5865f2",
        isCollapsed: Bool = false,
        splitLayout: SplitLayout? = nil,
        lock: FolderLock? = nil,
        isUnlocked: Bool = false
    ) {
        self.id = id
        self.spaceId = spaceId
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.splitLayout = splitLayout
        self.lock = lock
        self.isUnlocked = isUnlocked
    }

    var bridgeData: [String: Any] {
        var data: [String: Any] = [
            "id": id.uuidString,
            "spaceId": spaceId.uuidString,
            "name": name,
            "color": color,
            // A locked folder renders closed: the sidebar's collapse path already hides its tabs.
            "isCollapsed": isCollapsed || isLocked,
            "isSplit": isSplit,
            "isLocked": isLocked,
            "lock": lock.map {
                ["allowsBiometrics": $0.allowsBiometrics, "biometricsAvailable": FolderLockAuth.biometricsAvailableAtLaunch]
            } ?? NSNull()
        ]
        if let splitLayout { data["splitLayout"] = splitLayout.bridgeData }
        return data
    }
}
