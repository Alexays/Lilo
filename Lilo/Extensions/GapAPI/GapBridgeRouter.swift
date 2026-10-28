import Foundation
import WebKit

/// One gap API call, authenticated by `GapBridgeRouter`: `extensionId` is the extension that owns
/// the calling page or worker, never a value the caller supplied, and `registry` is its profile's.
struct GapCall: PayloadReading {
    /// `namespace.method`.
    let action: String
    let extensionId: String
    /// The caller's context; nil only for a test's call from no loaded extension.
    let context: WKWebExtensionContext?
    let registry: ProfileExtensionRegistry
    let payload: [String: Any]
}

/// Implements Chrome APIs WebKit lacks. Returns the success payload, or a `BridgeError`.
@MainActor
protocol GapHandler {
    var gapActions: Set<String> { get }
    func handle(_ call: GapCall) async -> Any?
}

extension GapHandler {
    /// The body's value is the success payload; a thrown error becomes the bridge failure.
    func bridged<T>(_ body: () throws -> T) -> Any? {
        do {
            return try body()
        } catch {
            return BridgeError(error.localizedDescription)
        }
    }
}

/// Routes the gap calls extension pages and workers send over their channel to Lilo (`GapEvents`) to
/// `GapHandler`s.
@MainActor
final class GapBridgeRouter {
    private var handlers: [String: any GapHandler] = [:]

    /// Manifest permissions a gap call requires, keyed by action (checked first) or namespace, as Chrome gates them; absent
    /// namespaces need none. `tabs` covers tabs.group/ungroup, bridged only alongside chrome.tabGroups.
    private static let requiredPermissions: [String: [String]] = [
        "bookmarks": ["bookmarks"],
        "browsingData": ["browsingData"],
        "contentSettings": ["contentSettings"],
        "debugger": ["debugger"],
        "desktopCapture": ["desktopCapture"],
        "downloads": ["downloads"],
        "downloads.open": ["downloads", "downloads.open"],
        "fontSettings": ["fontSettings"],
        "history": ["history"],
        "identity": ["identity"],
        "idle": ["idle"],
        "instanceID": ["gcm"],
        "management": ["management"],
        "mdns": ["mdns"],
        "management.getSelf": [],
        "management.getPermissionWarningsByManifest": [],
        "management.uninstallSelf": [],
        "notifications": ["notifications"],
        "offscreen": ["offscreen"],
        "pageCapture": ["pageCapture"],
        "proxy": ["proxy"],
        "power": ["power"],
        "search": ["search"],
        "sessions": ["sessions"],
        "sidePanel": ["sidePanel"],
        "system.cpu": ["system.cpu"],
        "system.display": ["system.display"],
        "system.memory": ["system.memory"],
        "system.network": ["system.network"],
        "system.storage": ["system.storage"],
        "tabCapture": ["tabCapture"],
        "tabGroups": ["tabGroups"],
        "tabs": ["tabGroups"],
        "tabs.discard": [],
        "tabs.getZoomSettings": [],
        "tabs.setZoomSettings": [],
        "tabs.createSplit": [],
        "tabs.unsplit": [],
        "tabs.details": [],
        "cookies": ["cookies"],
        "topSites": ["topSites"],
        "tts": ["tts"],
        "userScripts": ["userScripts"]
    ]

    func register(handler: any GapHandler) {
        handler.gapActions.forEach { handlers[$0] = handler }
    }

    // MARK: - Routing

    /// Looks up the handler for `namespace.method`, checks the caller's manifest permissions, and
    /// hands it the call, returning `(result, error)`. The caller is a page or the worker of
    /// `extensionId`, whose channel WebKit opened for that extension in `registry`'s profile.
    func route(
        namespace: String,
        method: String,
        params: [String: Any],
        extensionId: String,
        fromWorker: Bool,
        registry: ProfileExtensionRegistry
    ) async -> (result: Any?, error: String?) {
        let action = "\(namespace).\(method)"
        let signpost = PerfSignposts.extensions.beginInterval("gapCall", id: PerfSignposts.extensions.makeSignpostID(), "\(action)")
        defer { PerfSignposts.extensions.endInterval("gapCall", signpost) }
        #if DEBUG
        // An error of a page or the worker in full: WebKit keeps only a console.error's first argument.
        if action == "diagnostics.console" {
            registry.recordExtensionNativeDiagnostic(
                extensionId: extensionId, level: "error", source: params["source"] as? String ?? "page", message: params["message"] as? String ?? ""
            )
            return (nil, nil)
        }
        #endif
        let handler = handlers[action]
        guard handler != nil || namespace == "events" else {
            return (nil, "API not available: \(action)")
        }
        guard let caller = registry.gapCaller(extensionId) else {
            return (nil, "Gap API not available in this context")
        }
        guard let handler else {
            // The gap events a context listens to: the registry only queues, and wakes the worker for, those.
            let events = params["events"] as? [String] ?? []
            switch method {
            case "listen": await registry.addGapListeners(events, extensionId: extensionId, fromWorker: fromWorker)
            case "unlisten": registry.removeGapListeners(events, extensionId: extensionId, fromWorker: fromWorker)
            default: return (nil, "API not available: \(action)")
            }
            return (nil, nil)
        }
        let required = Self.requiredPermissions[action] ?? Self.requiredPermissions[namespace] ?? []
        // WebKit tracks grants (optional ones, removals) only for the permissions it knows; the others are
        // held when the manifest requires them or the user granted them at Lilo's prompt.
        if let missing = required.first(where: { name in
            caller.webKitPermissions.contains(name)
                ? !caller.context.hasPermission(WKWebExtension.Permission(rawValue: name))
                : !caller.held.contains(name)
        }) {
            return (nil, "Permission '\(missing)' is required for \(action)")
        }
        var params = params
        // Identity is `GapCall.extensionId`; a caller-supplied one must never be read.
        if params["extensionId"] != nil { params["extensionId"] = nil }
        let call = GapCall(action: action, extensionId: extensionId, context: caller.context, registry: registry, payload: params)
        let result = await handler.handle(call)
        if let error = (result as? BridgeError)?.message {
            return (nil, error)
        }
        return (result, nil)
    }
}
