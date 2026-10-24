import Foundation

/// Receives the chrome UI's tab-share picker resolution and hands it to the pending page request.
@MainActor
final class TabShareBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = ["tabShare.resolve"]

    private let resolve: (String, TabSharePickerChoice) -> Void

    init(resolve: @escaping (String, TabSharePickerChoice) -> Void) {
        self.resolve = resolve
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let requestId = message.string("requestId"), let choice = message.string("choice") else { return nil }
        switch choice {
        case "tab":
            guard let tabId = message.uuid("tabId") else {
                resolve(requestId, .cancel)
                return nil
            }
            resolve(requestId, .tab(tabId))
        case "system":
            resolve(requestId, .system)
        default:
            resolve(requestId, .cancel)
        }
        return nil
    }
}
