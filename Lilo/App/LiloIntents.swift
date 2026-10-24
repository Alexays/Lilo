import AppIntents
import AppKit

// Shortcuts actions and the Focus filter. They run in the app, against the window the user last
// worked in. Private spaces are never offered: they are not meant to outlive their window.

@MainActor
private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

struct SpaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    static let defaultQuery = SpaceQuery()

    let id: UUID
    let name: String
    let icon: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(icon) \(name)") }
}

struct SpaceQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SpaceEntity] {
        allSpaces().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SpaceEntity] { allSpaces() }

    @MainActor
    private func allSpaces() -> [SpaceEntity] {
        let spaces = appDelegate?.browserContext.spaceManager?.spaces ?? []
        return spaces.filter { !$0.isPrivate }.map { SpaceEntity(id: $0.id, name: $0.name, icon: $0.icon) }
    }
}

struct OpenURLInLiloIntent: AppIntent {
    static let title: LocalizedStringResource = "Open URL in Lilo"
    static let openAppWhenRun = true

    @Parameter(title: "URL")
    var url: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        appDelegate?.application(NSApp, open: [url])
        return .result()
    }
}

struct GetCurrentTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Tab"
    static let description = IntentDescription("The address of the tab shown in the front Lilo window.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL?> {
        guard let controller = appDelegate?.mainWindowController,
              controller.context.spaceManager?.space(with: controller.tabManager.currentSpaceId)?.isPrivate == false else { return .result(value: nil) }
        return .result(value: controller.tabManager.activeTab?.url)
    }
}

struct OpenSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Space"
    static let openAppWhenRun = true

    @Parameter(title: "Space")
    var space: SpaceEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        appDelegate?.mainWindowController?.requestSpaceSwitch(id: space.id)
        return .result()
    }
}

/// Picks the space Lilo shows while a Focus is on.
struct LiloFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Lilo Space"
    static let description: IntentDescription? = "Shows this space in Lilo while the Focus is on."

    @Parameter(title: "Space")
    var space: SpaceEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: space.map { "\($0.icon) \($0.name)" } ?? "No space")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let space { appDelegate?.mainWindowController?.requestSpaceSwitch(id: space.id) }
        return .result()
    }
}

struct LiloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSpaceIntent(), phrases: ["Open a space in \(.applicationName)"],
                    shortTitle: "Open Space", systemImageName: "square.stack")
        AppShortcut(intent: GetCurrentTabIntent(), phrases: ["Get the current tab in \(.applicationName)"],
                    shortTitle: "Current Tab", systemImageName: "link")
    }
}
