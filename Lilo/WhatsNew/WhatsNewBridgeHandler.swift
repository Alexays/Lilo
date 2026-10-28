import Foundation

@MainActor
final class WhatsNewBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = ["requestWhatsNew", "whatsNewPresented", "dismissWhatsNew"]
    private weak var windowController: MainWindowController?

    init(windowController: MainWindowController) { self.windowController = windowController }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {
        case "requestWhatsNew": windowController?.requestAutomaticWhatsNew()
        case "whatsNewPresented":
            if let version = message.string("version") { windowController?.acknowledgeWhatsNew(version: version) }
        case "dismissWhatsNew": windowController?.dismissWhatsNew()
        default: break
        }
        return nil
    }
}
