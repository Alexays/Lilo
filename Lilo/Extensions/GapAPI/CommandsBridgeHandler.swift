import WebKit

/// Gap API handler for chrome.commands.
@MainActor
final class CommandsBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["commands.getAll"]

    func handle(_ call: GapCall) async -> Any? {
        let commands = call.context?.commands.map { command in
            ["name": command.id, "description": command.title, "shortcut": command.activationKey ?? ""]
        } ?? []
        return ["commands": commands]
    }
}
