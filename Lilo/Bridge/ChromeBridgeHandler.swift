import Foundation

/// Handles chrome UI bridge messages: sidebar resize, interactive zones, readiness.
/// Tab/navigation actions are handled by TabBridgeHandler.
@MainActor
final class ChromeBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = [
        "sidebarResized",
        "toggleSidebar",
        "setSidebarCollapseLocked",
        "maximizeWindow",
        "startWindowDrag",
        "showTabSecurityInfo",
        "showBackHistoryMenu",
        "showForwardHistoryMenu",
        "registerInteractiveZones",
        "removeInteractiveZone",
        "traceSpaceSwipe",
        "traceSpaceDnd",
        "ready",
        "startupMark",
        "chromeVisualReady",
        "initialStateApplied",
        "permissionResponse",
        "extensionPermissionResponse",
        "updateWindowBackground",
        "setWallpaperColorWatch",
        "sidebarOverlayChanged",
        "showTabContextMenu",
        "showFolderContextMenu",
        "showSidebarContextMenu",
        "showExtensionContextMenu",
        "showDownloadContextMenu",
        "allowCertificateException"
    ]

    private let interactiveZoneStore: ChromeInteractiveZoneStore
    private weak var windowController: MainWindowController?

    init(interactiveZoneStore: ChromeInteractiveZoneStore, windowController: MainWindowController) {
        self.interactiveZoneStore = interactiveZoneStore; self.windowController = windowController
    }

    private func anchorRect(from message: BridgeMessage) -> NSRect? {
        guard let x = message.cgFloat("x"), let y = message.cgFloat("y"),
              let w = message.cgFloat("width"), let h = message.cgFloat("height") else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {

        case "sidebarResized":
            if let width = message.cgFloat("width") { windowController?.updateSidebarWidth(width) }

        case "toggleSidebar":
            windowController?.toggleSidebar()

        case "setSidebarCollapseLocked":
            windowController?.setSidebarCollapseLocked(message.bool("locked"))

        case "maximizeWindow":
            windowController?.window?.zoom(nil)

        case "startWindowDrag":
            windowController?.startWindowDrag()

        case "showTabSecurityInfo":
            windowController?.showActiveTabSecurityInfo()

        case "allowCertificateException":
            if let host = message.string("host") { windowController?.allowInsecureTrust(forHost: host) }

        case "showBackHistoryMenu":
            windowController?.showNavigationHistoryMenu(direction: .back, anchorRect: anchorRect(from: message))

        case "showForwardHistoryMenu":
            windowController?.showNavigationHistoryMenu(direction: .forward, anchorRect: anchorRect(from: message))

        case "registerInteractiveZones":
            let zones = (message.payload["zones"] as? [[String: Any]] ?? []).compactMap { zone -> (id: String, rect: NSRect)? in
                guard let id = zone["id"] as? String,
                      let x = zone["x"] as? NSNumber, let y = zone["y"] as? NSNumber,
                      let width = zone["width"] as? NSNumber, let height = zone["height"] as? NSNumber else { return nil }
                return (id, NSRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue))
            }
            interactiveZoneStore.registerZones(zones)

        case "removeInteractiveZone":
            if let id = message.string("id") { interactiveZoneStore.removeZone(id: id) }

        case "traceSpaceSwipe":
            // The field extraction rides inside trace's autoclosure: skipped entirely when tracing
            // is off (these fire per swipe frame).
            StartupMetrics.trace("swipe-ui", """
                stage=\(message.string("stage", default: "unknown")) source=\(message.string("source", default: "ui")) \
                active=\(message.string("activeSpaceId", default: "")) focused=\(message.string("focusedSpaceId", default: "")) \
                target=\(message.string("targetId", default: "")) transition=\(message.string("transitionId", default: "")) \
                virtualIndex=\(String(format: "%.3f", message.double("virtualIndex") ?? -1)) \
                scrollLeft=\(String(format: "%.1f", message.double("scrollLeft") ?? -1)) \
                width=\(String(format: "%.1f", message.double("width") ?? -1)) \
                anchor=\(String(format: "%.2f", message.double("anchorIndex") ?? -1))
                """)

        case "traceSpaceDnd":
            // Formatted lazily like traceSpaceSwipe; these fire per drag frame.
            StartupMetrics.trace("space-dnd", """
                stage=\(message.string("stage", default: "unknown")) event=\(message.string("event", default: "")) \
                id=\(message.string("id", default: "")) trigger=\(message.string("trigger", default: "")) \
                source=\(message.string("source", default: "")) shadowIndex=\(message.int("shadowIndex") ?? -1) \
                base=\(message.string("baseOrder", default: "")) items=\(message.string("itemsOrder", default: "")) \
                visual=\(message.string("visualOrder", default: ""))
                """)

        case "ready":
            StartupMetrics.mark("chromeReady", occurredAt: message.double("at"))
            windowController?.handleChromeReady()

        case "startupMark":
            let event = message.string("event", default: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !event.isEmpty { StartupMetrics.mark(event, occurredAt: message.double("at")) }

        case "initialStateApplied":
            windowController?.activateRestoredActiveRuntimeIfNeeded()

        case "chromeVisualReady":
            windowController?.handleChromeVisualReady(occurredAt: message.double("at"))

        case "permissionResponse":
            if let requestId = message.string("requestId").flatMap(UUID.init(uuidString:)) {
                windowController?.resolvePermissionRequest(
                    requestId: requestId, granted: message.bool("granted"), remember: message.bool("remember", default: true)
                )
            }

        case "extensionPermissionResponse":
            if let requestId = message.string("requestId") { windowController?.resolveExtensionPermissionRequest(requestId: requestId, granted: message.bool("granted")) }

        case "updateWindowBackground":
            if let color = message.string("color") { windowController?.applyWindowChromeColors(color) }

        case "setWallpaperColorWatch":
            windowController?.setWallpaperColorWatch(message.bool("enabled"))

        case "sidebarOverlayChanged":
            windowController?.handleSidebarOverlay(visible: message.bool("visible"))

        case "showTabContextMenu":
            if let id = message.string("id") { windowController?.showTabContextMenu(tabId: id, anchorRect: anchorRect(from: message)) }

        case "showFolderContextMenu":
            if let id = message.string("id") { windowController?.showFolderContextMenu(folderId: id, anchorRect: anchorRect(from: message)) }

        case "showSidebarContextMenu":
            windowController?.showSidebarContextMenu(spaceId: message.string("spaceId"), anchorRect: anchorRect(from: message))

        case "showExtensionContextMenu":
            if let id = message.string("id") {
                windowController?.showExtensionContextMenu(
                    extensionId: id,
                    anchorRect: anchorRect(from: message),
                    pinned: message.payload["pinned"] as? Bool,
                    profileId: message.uuid("profileId")
                )
            }

        case "showDownloadContextMenu":
            if let id = message.int("id") {
                windowController?.showDownloadContextMenu(
                    downloadId: id,
                    anchorRect: anchorRect(from: message),
                    state: message.string("state", default: "complete"),
                    fileMissing: message.bool("fileMissing")
                )
            }

        default:
            break
        }

        return nil
    }
}
