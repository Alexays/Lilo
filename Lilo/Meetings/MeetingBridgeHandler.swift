/// The meeting card's buttons.
@MainActor
final class MeetingBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = ["joinMeeting", "dismissMeeting"]

    private weak var windowController: MainWindowController?

    init(windowController: MainWindowController) {
        self.windowController = windowController
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let id = message.string("id") else { return nil }
        switch message.action {
        case "joinMeeting": windowController?.joinMeeting(id)
        case "dismissMeeting": windowController?.context.meetings?.dismiss(id)
        default: break
        }
        return nil
    }
}
