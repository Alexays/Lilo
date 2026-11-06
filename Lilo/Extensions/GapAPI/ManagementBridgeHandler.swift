import AppKit
import WebKit

/// Implements the chrome.management API as a BridgeHandler.
/// Provides methods: getAll, get, getSelf, setEnabled, uninstall, uninstallSelf, getPermissionWarningsById,
/// getPermissionWarningsByManifest. Its events come from `ProfileExtensionRegistry`, which every install,
/// enable, disable and removal goes through.
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
        let loaded = registry.loadedExtensions.compactMap { registry.extensionInfo(for: $0.id) }
        let disabled = registry.disabledStoredExtensions.map { disabledInfo($0, registry: registry) }
        return (loaded + disabled).sorted { $0.id < $1.id }.map(\.dictionary)
    }

    private func handleGet(id: String, registry: ProfileExtensionRegistry?) -> Any? {
        guard let registry else { return BridgeError("Extension not found") }
        if let info = registry.extensionInfo(for: id) { return info.dictionary }
        guard let stored = registry.disabledStoredExtensions.first(where: { $0.id == id }) else {
            return BridgeError("Extension not found")
        }
        return disabledInfo(stored, registry: registry).dictionary
    }

    /// A disabled extension has no loaded manifest: the installed copy is read from disk, its name
    /// recorded localized at its last load and its other `__MSG_` strings resolved here.
    private func disabledInfo(_ stored: ExtensionStorage.InstalledExtension, registry: ProfileExtensionRegistry) -> ExtensionInfo {
        let folder = URL(fileURLWithPath: stored.path)
        var manifest = (try? Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0, options: .json5Allowed) as? [String: Any] } ?? ["version": stored.version]
        let locale = manifest["default_locale"] as? String
        manifest["name"] = stored.name
        for key in ["short_name", "description"] {
            guard let value = manifest[key] as? String else { continue }
            manifest[key] = ExtensionInstallReview.resolveLocalizedMessage(value, defaultLocale: locale, extensionURL: folder)
        }
        return ExtensionInfoBuilder.buildFromManifest(
            manifest: manifest, id: stored.id, folder: folder, enabled: false,
            installType: registry.files.owns(stored.path) ? "normal" : "development"
        )
    }

    private func handleUninstall(id: String, confirm: Bool, caller: String, registry: ProfileExtensionRegistry?) async -> Any? {
        guard let registry else { return BridgeError("No active profile") }
        let name = registry.context(for: id)?.webExtension.displayName
            ?? registry.disabledStoredExtensions.first { $0.id == id }?.name
        guard let name else { return BridgeError("Extension not found: \(id)") }
        if confirm {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = unsafe String(format: "Remove %@?".localized, name)
            if id != caller, let callerName = registry.context(for: caller)?.webExtension.displayName {
                alert.informativeText = unsafe String(format: "Requested by the extension %@.".localized, callerName)
            }
            alert.addButton(withTitle: "Remove".localized)
            alert.addButton(withTitle: "Cancel".localized)
            guard alert.runModal() == .alertFirstButtonReturn else { return BridgeError("User cancelled uninstall") }
        }
        // A self-uninstall answers first: its own context goes away with the unload.
        if id == caller {
            Task { @MainActor in await registry.unload(extensionId: id) }
        } else {
            await registry.unload(extensionId: id)
        }
        return nil
    }

    private func handleGetSelf(extensionId: String, registry: ProfileExtensionRegistry?) -> Any? {
        guard let info = registry?.extensionInfo(for: extensionId) else {
            return BridgeError("Extension not found: \(extensionId)")
        }
        return info.dictionary
    }

    private func handleSetEnabled(id: String, enabled: Bool, registry: ProfileExtensionRegistry?) async -> Any? {
        guard let registry else { return BridgeError("No active profile") }
        guard !id.isEmpty else { return BridgeError("Missing id") }
        do {
            if enabled {
                try await registry.enable(extensionId: id)
                guard registry.context(for: id) != nil else { return BridgeError("Extension not found: \(id)") }
            } else {
                await registry.disable(extensionId: id)
            }
            return nil
        } catch {
            return BridgeError(error.localizedDescription)
        }
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
