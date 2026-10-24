import WebKit

/// `permissions.addHostAccessRequest` and `removeHostAccessRequest`: the profile's `ExtensionAccess`
/// keeps each request on its tab and offers it in the extensions menu. `permissions.request`, `remove`
/// and `held` for the optional permissions WebKit grants no request for (Gap API ones, `nativeMessaging`).
@MainActor
final class PermissionsBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "permissions.addHostAccessRequest", "permissions.removeHostAccessRequest",
        "permissions.request", "permissions.remove", "permissions.held"
    ]

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry
        switch call.action {
        case "permissions.request":
            return await request(call)
        case "permissions.remove":
            let required = call.context?.webExtension.manifest["permissions"] as? [String] ?? []
            let names = Set(call.payload["permissions"] as? [String] ?? []).subtracting(required)
            await registry.setGapPermissions(names, granted: false, extensionId: call.extensionId)
            return true
        case "permissions.held":
            return registry.heldPermissions(of: call.extensionId).sorted()
        default:
            break
        }
        guard let tab = registry.tabAdapters(atPositions: [call.payload["tab"] as? [String: Any] ?? [:]], extensionId: call.extensionId).first ?? nil else {
            return BridgeError("No tab with id: \(call.int("tabId") ?? -1).")
        }
        let error = call.action == "permissions.addHostAccessRequest"
            ? registry.access.addHostAccessRequest(extensionId: call.extensionId, tab: tab, pattern: call.string("pattern"))
            : registry.access.removeHostAccessRequest(extensionId: call.extensionId, tab: tab, pattern: call.string("pattern"))
        return error.map(BridgeError.init)
    }

    /// One prompt for the whole request, as Chrome shows: what WebKit knows is then granted on the
    /// context (WebKit persists it through `ExtensionAccess`), the rest is kept by Lilo.
    private func request(_ call: GapCall) async -> Any? {
        let registry = call.registry
        guard let context = call.context else { return BridgeError("Extension not loaded.") }
        let webExtension = context.webExtension
        let names = call.payload["permissions"] as? [String] ?? []
        let origins = call.payload["origins"] as? [String] ?? []
        let declared = Set((webExtension.manifest["permissions"] as? [String] ?? []) + (webExtension.manifest["optional_permissions"] as? [String] ?? []))
        let declaredPatterns = webExtension.allRequestedMatchPatterns.union(webExtension.optionalPermissionMatchPatterns)
        let patterns = origins.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        guard names.allSatisfy(declared.contains), patterns.count == origins.count,
              patterns.allSatisfy({ pattern in declaredPatterns.contains { $0.matches(pattern) } }) else {
            return BridgeError("Only permissions specified in the manifest may be requested.")
        }
        // WebKit's nativeMessaging is granted to every extension for its channel to Lilo, so Lilo keeps its grant.
        let known = names.map(WKWebExtension.Permission.init(rawValue:))
            .filter { webExtension.optionalPermissions.contains($0) && $0 != .nativeMessaging }
        let missingKnown = known.filter { !context.hasPermission($0) }
        let missingGap = Set(names).subtracting(known.map(\.rawValue)).subtracting(registry.heldPermissions(of: call.extensionId))
        let missingPatterns = patterns.filter {
            context.permissionStatus(for: $0).rawValue < WKWebExtensionContext.PermissionStatus.grantedImplicitly.rawValue
        }
        guard !missingKnown.isEmpty || !missingGap.isEmpty || !missingPatterns.isEmpty else { return true }
        let granted = await registry.delegate.promptForPermissions(
            missingGap.sorted() + missingKnown.map(\.rawValue), origins: missingPatterns.map(\.description), for: context
        )
        guard granted, registry.context(for: call.extensionId) === context else { return false }
        missingKnown.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        missingPatterns.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        await registry.setGapPermissions(missingGap, granted: true, extensionId: call.extensionId)
        return true
    }
}
