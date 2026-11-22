import Foundation

/// What a Little window's chrome asks of its window: its command bar's navigations, the strip's buttons, its
/// interactive zones and the few settings the bar reads. Every other action the chrome might send is ignored.
@MainActor
final class LittleWindowBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = [
        "littleReady", "littleOpenInSpace", "littleCopyLink", "littleClose",
        "navigate", "createTab", "focusPage", "startWindowDrag",
        "registerInteractiveZones", "removeInteractiveZone", "getSettings"
    ]
    /// The settings the bar reads: nothing else of the user's leaves the app for its page.
    private static let sharedSettings = ["searchEngine", "searchEngines", "searchSuggestions", "locale"]

    private weak var little: LittleWindowController?

    init(little: LittleWindowController) {
        self.little = little
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let little else { return nil }
        switch message.action {
        case "littleReady":
            little.chromeDidLoad()
        case "littleOpenInSpace":
            little.openInSpace(message.uuid("spaceId") ?? little.spaceId)
        case "littleCopyLink":
            little.copyCurrentURL(nil)
        case "littleClose":
            little.window.performClose(nil)
        case "navigate":
            if let url = message.url("url") { little.navigate(to: url) }
        case "createTab":
            if let url = message.url("url") { little.openAsTab(url) }
        case "focusPage":
            little.focusPage()
        case "startWindowDrag":
            little.startWindowDrag()
        case "registerInteractiveZones":
            let zones = (message.payload["zones"] as? [[String: Any]] ?? []).compactMap { zone -> (id: String, rect: NSRect)? in
                guard let id = zone["id"] as? String,
                      let x = zone["x"] as? NSNumber, let y = zone["y"] as? NSNumber,
                      let width = zone["width"] as? NSNumber, let height = zone["height"] as? NSNumber else { return nil }
                return (id, NSRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue))
            }
            little.chromeHost.zones.registerZones(zones)
        case "removeInteractiveZone":
            if let id = message.string("id") { little.chromeHost.zones.removeZone(id: id) }
        case "getSettings":
            little.sendSharedSettings(Self.sharedSettings)
        default:
            break
        }
        return nil
    }
}
