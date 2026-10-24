import AppKit
import WebKit

/// Implements the chrome.management API as a BridgeHandler.
/// Provides methods: getAll, get, getSelf, setEnabled, uninstall, uninstallSelf, getPermissionWarningsById,
/// getPermissionWarningsByManifest. Events: onEnabled, onDisabled, onUninstalled
@MainActor
final class ManagementBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "management.getAll",
        "management.get",
        "management.getSelf",
        "management.setEnabled",
        "management.uninstall",
        "management.uninstallSelf",
        "management.getPermissionWarningsById",
        "management.getPermissionWarningsByManifest",
        "management.launchApp",
        "management.createAppShortcut",
        "management.setLaunchType",
        "management.generateAppForLink"
    ]

    func handle(_ call: GapCall) async -> Any? {
        let resolved = call.registry
        switch call.action {
        case "management.getAll":       return handleGetAll(registry: resolved)
        case "management.get":          return handleGet(id: call.string("id") ?? "", registry: resolved)
        case "management.getSelf":      return handleGetSelf(extensionId: call.extensionId, registry: resolved)
        case "management.setEnabled":   return await handleSetEnabled(id: call.string("id") ?? "", enabled: call.bool("enabled"), registry: resolved)
        case "management.uninstall":
            // As in Chrome, removing another extension always asks the user.
            let caller = call.extensionId
            let id = call.string("id") ?? ""
            return await handleUninstall(id: id, confirm: id != caller || call.bool("showConfirmDialog"), caller: caller, registry: resolved)
        case "management.uninstallSelf":
            let caller = call.extensionId
            return await handleUninstall(id: caller, confirm: call.bool("showConfirmDialog"), caller: caller, registry: resolved)
        case "management.getPermissionWarningsById":      return handleGetPermissionWarningsById(id: call.string("id") ?? "", registry: resolved)
        case "management.getPermissionWarningsByManifest": return handleGetPermissionWarningsByManifest(call)
        case "management.launchApp":    return notAnApp(id: call.string("id") ?? "", registry: resolved)
        case "management.createAppShortcut":
            guard call.bool("userGesture") else { return BridgeError("chrome.management.createAppShortcut requires a user gesture.") }
            return notAnApp(id: call.string("id") ?? "", registry: resolved)
        case "management.setLaunchType":
            guard call.bool("userGesture") else { return BridgeError("chrome.management.setLaunchType requires a user gesture.") }
            return notAnApp(id: call.string("id") ?? "", registry: resolved)
        case "management.generateAppForLink":    return handleGenerateAppForLink(call)
        default:                        return nil
        }
    }

    // MARK: - Private Helpers

    /// Lilo runs MV3 extensions only, never an app: Chrome's answer for an installed non-app.
    private func notAnApp(id: String, registry: ProfileExtensionRegistry) -> BridgeError {
        let installed = registry.context(for: id) != nil || registry.disabledStoredExtensions.contains { $0.id == id }
        return BridgeError(installed ? "Extension \(id) is not an App." : "Failed to find extension with id \(id).")
    }

    /// Chrome's checks, then a failure: Lilo installs no web apps.
    private func handleGenerateAppForLink(_ call: GapCall) -> BridgeError {
        guard call.bool("userGesture") else { return BridgeError("chrome.management.generateAppForLink requires a user gesture.") }
        let url = call.string("url") ?? ""
        guard let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https", URL(string: url)?.host?.isEmpty == false else {
            return BridgeError("The URL \"\(url)\" is invalid.")
        }
        guard call.string("title")?.isEmpty == false else { return BridgeError("The title can not be empty.") }
        return BridgeError("Failed to install the generated app.")
    }

    /// Disabled extensions are listed too, as in Chrome, so a manager can find and re-enable them.
    private func handleGetAll(registry: ProfileExtensionRegistry?) -> [[String: Any]] {
        guard let registry else { return [] }
        let loaded = registry.loadedExtensions
            .map { ExtensionInfoBuilder.buildFromManifest(manifest: $0.context.webExtension.manifest, id: $0.id) }
        let disabled = registry.disabledStoredExtensions.map(disabledInfo)
        return (loaded + disabled).sorted { $0.id < $1.id }.map(infoDict)
    }

    private func handleGet(id: String, registry: ProfileExtensionRegistry?) -> Any? {
        guard let registry else { return BridgeError("Extension not found") }
        if let context = registry.context(for: id) {
            return infoDict(ExtensionInfoBuilder.buildFromManifest(manifest: context.webExtension.manifest, id: id))
        }
        guard let stored = registry.disabledStoredExtensions.first(where: { $0.id == id }) else {
            return BridgeError("Extension not found")
        }
        return infoDict(disabledInfo(stored))
    }

    /// A disabled extension has no loaded manifest: the installed copy is read from disk.
    private func disabledInfo(_ stored: ExtensionStorage.InstalledExtension) -> ExtensionInfo {
        let manifestURL = URL(fileURLWithPath: stored.path).appendingPathComponent("manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["name": stored.name, "version": stored.version]
        return ExtensionInfoBuilder.buildFromManifest(manifest: manifest, id: stored.id, enabled: false)
    }

    private func handleUninstall(id: String, confirm: Bool, caller: String, registry: ProfileExtensionRegistry?) async -> Any? {
        guard let registry else { return BridgeError("No active profile") }
        let name = registry.context(for: id)?.webExtension.displayName
            ?? registry.disabledStoredExtensions.first { $0.id == id }?.name
        guard let name else { return BridgeError("Extension not found: \(id)") }
        if confirm {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(format: "Remove %@?".localized, name)
            if id != caller, let callerName = registry.context(for: caller)?.webExtension.displayName {
                alert.informativeText = String(format: "Requested by the extension %@.".localized, callerName)
            }
            alert.addButton(withTitle: "Remove".localized)
            alert.addButton(withTitle: "Cancel".localized)
            guard alert.runModal() == .alertFirstButtonReturn else { return BridgeError("User cancelled uninstall") }
        }
        // A self-uninstall answers first: its own context goes away with the unload.
        if id == caller {
            Task { @MainActor in await Self.uninstall(id, from: registry) }
        } else {
            await Self.uninstall(id, from: registry)
        }
        return nil
    }

    private static func uninstall(_ id: String, from registry: ProfileExtensionRegistry) async {
        await registry.unload(extensionId: id)
        registry.emitGapEvent("management", "onUninstalled", args: [id], requiredPermission: "management")
    }

    private func handleGetSelf(extensionId: String, registry: ProfileExtensionRegistry?) -> Any? {
        guard let registry,
              let entry = registry.loadedExtensions.first(where: { $0.id == extensionId }) else {
            return BridgeError("Extension not found: \(extensionId)")
        }
        return infoDict(ExtensionInfoBuilder.buildFromManifest(
            manifest: entry.context.webExtension.manifest,
            id: entry.id
        ))
    }

    /// Enables (load) or disables (unload) an extension through the registry, then fires the matching
    /// management event. The onDisabled payload is built before unloading, while the manifest is still
    /// reachable, and its `enabled` flag is forced to the new state.
    private func handleSetEnabled(id: String, enabled: Bool, registry: ProfileExtensionRegistry?) async -> Any? {
        guard let registry else { return BridgeError("No active profile") }
        guard !id.isEmpty else { return BridgeError("Missing id") }
        do {
            if enabled {
                try await registry.enable(extensionId: id)
                guard let context = registry.context(for: id) else { return BridgeError("Extension not found: \(id)") }
                var info = infoDict(ExtensionInfoBuilder.buildFromManifest(manifest: context.webExtension.manifest, id: id))
                info["enabled"] = true
                registry.emitGapEvent("management", "onEnabled", args: [info], requiredPermission: "management")
            } else {
                let context = registry.context(for: id)
                await registry.disable(extensionId: id)
                if let context {
                    var info = infoDict(ExtensionInfoBuilder.buildFromManifest(manifest: context.webExtension.manifest, id: id))
                    info["enabled"] = false
                    registry.emitGapEvent("management", "onDisabled", args: [info], requiredPermission: "management")
                }
            }
            return nil
        } catch {
            return BridgeError(error.localizedDescription)
        }
    }

    /// Chrome's ExtensionInfo, the same shape for getAll, get and getSelf. Nil optionals are omitted.
    private func infoDict(_ ext: ExtensionInfo) -> [String: Any] {
        var dict: [String: Any] = [
            "id": ext.id,
            "name": ext.name,
            "shortName": ext.shortName,
            "description": ext.description,
            "version": ext.version,
            "enabled": ext.enabled,
            "type": ext.type,
            "installType": ext.installType,
            "icons": ext.icons.map { ["size": $0.size, "url": $0.url] },
            "permissions": ext.permissions,
            "hostPermissions": ext.hostPermissions,
            "offlineEnabled": ext.offlineEnabled,
            "disableReasons": ext.disableReasons
        ]
        if let versionName = ext.versionName { dict["versionName"] = versionName }
        if let homepageUrl = ext.homepageUrl { dict["homepageUrl"] = homepageUrl }
        if let updateUrl = ext.updateUrl { dict["updateUrl"] = updateUrl }
        if let optionsUrl = ext.optionsUrl { dict["optionsUrl"] = optionsUrl }
        return dict
    }

    private func handleGetPermissionWarningsById(id: String, registry: ProfileExtensionRegistry?) -> [String: Any] {
        guard let registry,
              let ext = registry.context(for: id)?.webExtension else {
            return ["warnings": []]
        }
        return ["warnings": getPermissionWarningsByManifest(manifest: ext.manifest)]
    }

    private func handleGetPermissionWarningsByManifest(_ call: GapCall) -> [String: Any] {
        let manifest: [String: Any]
        if let dict = call.payload["manifest"] as? [String: Any] {
            manifest = dict
        } else if let manifestStr = call.string("manifestStr"),
                  let data = manifestStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            manifest = parsed
        } else {
            manifest = [:]
        }
        return ["warnings": getPermissionWarningsByManifest(manifest: manifest)]
    }

    private func getPermissionWarningsByManifest(manifest: [String: Any]) -> [String] {
        var warnings: [String] = []
        if let permissions = manifest["permissions"] as? [String] { warnings.append(contentsOf: warningsForPermissions(permissions)) }
        if let hostPerms = manifest["host_permissions"] as? [String] { warnings.append(contentsOf: warningsForHostPermissions(hostPerms)) }
        return warnings
    }

    private func warningsForPermissions(_ permissions: [String]) -> [String] {
        let dangerous = Set(["tabs", "webRequest", "management", "identity", "history", "cookies"])
        return permissions.filter { dangerous.contains($0) }.map { "This extension requests the \"\($0)\" permission" }
    }

    private func warningsForHostPermissions(_ hostPerms: [String]) -> [String] {
        let broad = ["https://*/*", "http://*/*", "*://*/*"]
        return hostPerms.filter { p in broad.contains { p.contains($0) } }.map { "This extension can access your data on \($0)" }
    }
}
