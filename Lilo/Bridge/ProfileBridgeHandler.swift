import Foundation
import os

/// Handles profile-related bridge messages from the Svelte chrome UI.
@MainActor
final class ProfileBridgeHandler: BridgeHandler {

    private static let logger = Logger(liloCategory: "bridge")

    let handledActions: Set<String> = [
        "createProfile",
        "deleteProfile",
        "updateProfile",
        "getProfileStats"
    ]

    private weak var profileManager: ProfileManager?
    private weak var windowController: MainWindowController?

    init(profileManager: ProfileManager, windowController: MainWindowController) {
        self.profileManager = profileManager
        self.windowController = windowController
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let profileManager else { return nil }

        switch message.action {

        case "createProfile":
            do {
                _ = try profileManager.createProfile(name: message.string("name", default: "New Profile"), color: message.string("color"))
            } catch {
                Self.logger.error("createProfile failed: \(error.localizedDescription)")
            }

        case "deleteProfile":
            // `moveTo` takes the profile's spaces first, and its default role when it has it.
            guard let id = message.uuid("id") else { break }
            let successor = message.uuid("moveTo")
            do {
                if let windowController {
                    let context = windowController.context
                    let agentsSpaceIds = context.settingsStore?.agentsSpaceIds ?? []
                    for space in context.spaceManager?.spaces(for: id) ?? [] where !space.isPrivate {
                        // Agents working in this profile go back to their own throwaway one.
                        if agentsSpaceIds.contains(space.id) {
                            try context.agentControl.returnAgents(from: space)
                        } else if let successor {
                            try await windowController.moveSpaceToProfile(id: space.id, targetProfileId: successor, name: nil, icon: nil, color: nil)
                        }
                    }
                }
                try profileManager.deleteProfile(id: id, successor: successor)
            } catch { Self.logger.error("deleteProfile failed: \(error.localizedDescription)") }

        case "updateProfile":
            guard let id = message.uuid("id") else { break }
            let name = message.string("name"), color = message.string("color")
            do {
                try profileManager.updateProfile(id: id) { profile in
                    if let name { profile.name = name }
                    if let color { profile.color = color }
                }
            } catch { Self.logger.error("updateProfile failed: \(error.localizedDescription)") }

        case "getProfileStats":
            do {
                let counts = try await profileManager.extensionCounts()
                windowController?.bridgeRouter?.send(event: "profileStats", data: ["extensionCounts": counts])
            } catch { Self.logger.error("getProfileStats failed: \(error.localizedDescription)") }

        default:
            break
        }

        return nil
    }
}
