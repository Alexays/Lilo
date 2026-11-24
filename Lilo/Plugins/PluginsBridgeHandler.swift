import AppKit
import Foundation
import PluginCore

/// The plugins panel's native side, against the fixed contract in `protocol.ts`: the six
/// commands below, and a `pluginsChanged` push with the full `BridgePluginRow` list after each —
/// `getPlugins` included, since it is how the panel first asks for the list.
@MainActor
final class PluginsBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = [
        "getPlugins", "setPluginEnabled", "setPluginSetting",
        "revokePluginCapability", "showPluginInFinder", "stopPlugin"
    ]

    private let host: PluginHost
    private weak var bridgeRouter: BridgeRouter?

    init(host: PluginHost, bridgeRouter: BridgeRouter) {
        self.host = host
        self.bridgeRouter = bridgeRouter
        host.onChanged = { [weak self] in
            Task { @MainActor in self?.publish() }
        }
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {

        case "getPlugins":
            await host.refresh()
            publish()

        case "setPluginEnabled":
            if let id = message.string("id") {
                host.setEnabled(message.bool("enabled"), for: id)
                publish()
            }

        case "setPluginSetting":
            if let id = message.string("id"), let name = message.string("name"), let value = message.payload["value"] {
                host.setSetting(name: name, value: JSONValue(any: value), for: id)
                publish()
            }

        case "revokePluginCapability":
            if let id = message.string("id"), let capability = message.string("capability") {
                host.revokeCapability(capability, for: id)
                publish()
            }

        case "showPluginInFinder":
            if let id = message.string("id"), let folder = host.folderURL(for: id) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }

        case "stopPlugin":
            if let id = message.string("id") {
                await host.stop(id: id)
                publish()
            }

        default:
            break
        }
        return nil
    }

    private func publish() {
        Task { @MainActor in
            let rows = await host.pluginRows()
            bridgeRouter?.send(event: "pluginsChanged", data: ["plugins": rows])
        }
    }
}
