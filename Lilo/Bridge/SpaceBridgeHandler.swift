import Foundation
import os

/// Handles space-related bridge messages from the Svelte chrome UI.
@MainActor
final class SpaceBridgeHandler: BridgeHandler {
    private static let logger = Logger(liloCategory: "space-bridge")

    let handledActions: Set<String> = [
        "createSpace",
        "deleteSpace",
        "switchSpace",
        "moveTabToSpace",
        "moveFolderToSpace",
        "moveSpace",
        "updateSpace"
    ]

    private weak var spaceManager: SpaceManager?
    private weak var windowController: MainWindowController?

    init(spaceManager: SpaceManager, windowController: MainWindowController) {
        self.spaceManager = spaceManager; self.windowController = windowController
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let spaceManager else { return nil }

        switch message.action {

        case "createSpace":
            let name = message.string("name", default: "New Space")
            let icon = message.string("icon", default: "🌐")
            let color = message.string("color", default: "#5865f2")
            let isPrivate = message.bool("isPrivate")
            let profileId = createRequestedProfile(message) ?? message.uuid("profileId")
            let colorMode = Self.colorMode(message) ?? Space.fixedColorMode
            let material = Self.material(message) ?? Space.solidMaterial

            guard let windowController else { break }
            do {
                try windowController.createSpace(
                    name: name,
                    icon: icon,
                    color: color,
                    colorMode: colorMode,
                    material: material,
                    isPrivate: isPrivate,
                    targetProfileId: profileId
                )
            } catch {
                Self.logger.error("Failed to create space: \(String(describing: error), privacy: .public)")
            }

        case "deleteSpace":
            guard let id = message.uuid("id") else { break }
            do {
                guard let windowController else { break }
                try windowController.deleteSpace(id: id)
            } catch {
                Self.logger.error("Failed to delete space \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }

        case "switchSpace":
            guard let id = message.uuid("id") else { break }
            let transitionId = message.string("transitionId")
            guard let windowController else { break }
            windowController.requestSpaceSwitch(id: id, transitionId: transitionId)

        case "moveTabToSpace":
            guard let tabId = message.uuid("tabId"), let spaceId = message.uuid("spaceId") else { break }
            guard let windowController else { break }
            do { try windowController.moveToSpace(.tab, id: tabId, targetSpaceId: spaceId) } catch {
                Self.logger.error("Failed to move tab \(tabId.uuidString, privacy: .public) to space \(spaceId.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }

        case "moveFolderToSpace":
            guard let folderId = message.uuid("folderId"), let spaceId = message.uuid("spaceId") else { break }
            guard let windowController else { break }
            do { try windowController.moveToSpace(.folder, id: folderId, targetSpaceId: spaceId) } catch {
                Self.logger.error("Failed to move folder \(folderId.uuidString, privacy: .public) to space \(spaceId.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }

        case "moveSpace":
            guard let id = message.uuid("id"), let toIndex = message.int("toIndex") else {
                StartupMetrics.trace("space-dnd", "stage=bridgeMoveSpaceInvalid payload=\(message.payload)")
                break
            }

            StartupMetrics.trace(
                "space-dnd",
                "stage=bridgeMoveSpaceReceived id=\(id.uuidString) toIndex=\(toIndex) order=\(StartupMetrics.spaceOrderDescription(spaceManager.spaces))"
            )

            do { try spaceManager.moveSpace(id: id, toIndex: toIndex) } catch {
                Self.logger.error("Failed to move space \(id.uuidString, privacy: .public) to index \(toIndex, privacy: .public): \(String(describing: error), privacy: .public)")
            }

        case "updateSpace":
            guard let id = message.uuid("id") else {
                break
            }

            let name = message.string("name")
            let icon = message.string("icon")
            let color = message.string("color")
            let archiveAfterHours = message.int("archiveAfterHours")
            let colorMode = Self.colorMode(message)
            let material = Self.material(message)

            // The space is resolved first: a profile is created only for a space that exists to use it. An Agents
            // space keeps its profile: each agent switches its own, moving every agent's tabs would switch them all.
            if let sourceSpace = spaceManager.space(with: id),
               windowController?.context.settingsStore?.agentsSpaceIds.contains(id) != true,
               let profileUUID = createRequestedProfile(message) ?? message.uuid("profileId"),
               sourceSpace.profileId != profileUUID {
                do {
                    try await windowController?.moveSpaceToProfile(
                        id: id,
                        targetProfileId: profileUUID,
                        name: name,
                        icon: icon,
                        color: color
                    )
                } catch {
                    Self.logger.error("Failed to move space \(id.uuidString, privacy: .public) to profile \(profileUUID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                guard archiveAfterHours != nil || colorMode != nil || material != nil else { break }
                do {
                    try spaceManager.updateSpace(id: id) { space in
                        if let archiveAfterHours { space.archiveAfterHours = archiveAfterHours }
                        if let colorMode { space.colorMode = colorMode }
                        if let material { space.material = material }
                    }
                } catch {
                    Self.logger.error("Failed to update space \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                break
            }

            do {
                try spaceManager.updateSpace(id: id) { space in
                    if let icon { space.icon = icon }; if let color { space.color = color }; if let name { space.name = name }
                    if let archiveAfterHours { space.archiveAfterHours = archiveAfterHours }
                    if let colorMode { space.colorMode = colorMode }
                    if let material { space.material = material }
                }
            } catch {
                Self.logger.error("Failed to update space \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }

        default:
            break
        }

        return nil
    }

    private static func colorMode(_ message: BridgeMessage) -> String? {
        message.string("colorMode").flatMap { Space.colorModes.contains($0) ? $0 : nil }
    }

    private static func material(_ message: BridgeMessage) -> String? {
        message.string("material").flatMap { Space.materials.contains($0) ? $0 : nil }
    }

    /// The editor's "New profile" choice: the profile is created together with the space that uses it.
    private func createRequestedProfile(_ message: BridgeMessage) -> UUID? {
        guard let name = message.string("newProfileName")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let profileManager = windowController?.context.profileManager else { return nil }
        do {
            return try profileManager.createProfile(name: name, color: message.string("newProfileColor")).id
        } catch {
            Self.logger.error("Failed to create profile for space: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
