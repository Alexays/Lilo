import AppKit
import WebKit
import os

/// Native transport for the store's `chrome.webstorePrivate` shim, kept out of GapBridgeRouter: the store has no extension identity.
/// The origin is verified natively (the JS guard is not trusted) and every install still goes through the consent prompt.
@MainActor
final class WebstoreInstallHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let messageHandlerName = "liloWebstore"
    private static let logger = Logger(liloCategory: "webstore-install")

    private let registryProvider: @MainActor (WKWebView?) -> ProfileExtensionRegistry?
    private let confirmInstall: @MainActor (ExtensionInstallReview) -> Bool

    init(registryProvider: @escaping @MainActor (WKWebView?) -> ProfileExtensionRegistry?,
         confirmInstall: @escaping @MainActor (ExtensionInstallReview) -> Bool) {
        self.registryProvider = registryProvider
        self.confirmInstall = confirmInstall
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        let host = origin.host
        guard message.frameInfo.isMainFrame, origin.protocol == "https", ChromeMasquerade.isStoreHost(host) else {
            Self.logger.warning("Rejected webstore call from \(origin.protocol, privacy: .public)://\(host, privacy: .private)")
            return (nil, "not_permitted")
        }
        guard let body = message.body as? [String: Any] else { return (nil, "invalid") }
        let webView = message.webView
        switch body["action"] as? String ?? "install" {
        case "list":
            return (installedExtensions(registryProvider(webView)), nil)
        case "uninstall":
            guard let id = body["id"] as? String else { return (nil, "invalid_id") }
            guard let registry = registryProvider(webView) else { return (nil, "no_registry") }
            guard let name = registry.context(for: id)?.webExtension.displayName
                    ?? registry.disabledStoredExtensions.first(where: { $0.id == id })?.name else { return (nil, "not_installed") }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(format: "Remove %@?".localized, name)
            alert.addButton(withTitle: "Remove".localized)
            alert.addButton(withTitle: "Cancel".localized)
            guard alert.runModal() == .alertFirstButtonReturn else { return (nil, "user_cancelled") }
            await registry.unload(extensionId: id)
            return (true, nil)
        default:
            return await install(rawId: body["id"] as? String, webView: webView)
        }
    }

    /// Real installed-extension list for this profile, disabled ones included, so the store's shim
    /// reflects actual state on page load (button shows "Remove from Chrome" when present).
    private func installedExtensions(_ registry: ProfileExtensionRegistry?) -> [[String: Any]] {
        guard let registry else { return [] }
        let enabled = registry.loadedExtensions.map { entry -> [String: Any] in
            let info = ExtensionInfoBuilder.buildFromManifest(manifest: entry.context.webExtension.manifest, id: entry.id)
            return ["id": info.id, "name": info.name, "version": info.version, "enabled": true]
        }
        let disabled = registry.disabledStoredExtensions.map { ["id": $0.id, "name": $0.name, "version": $0.version, "enabled": false] as [String: Any] }
        return enabled + disabled
    }

    private func install(rawId: String?, webView: WKWebView?) async -> (Any?, String?) {
        guard let rawId,
              let detailURL = URL(string: "https://chromewebstore.google.com/detail/x/\(rawId)"),
              let id = ChromeWebStoreInstaller.extensionId(from: detailURL)
        else { return (nil, "invalid_id") }
        guard let registry = registryProvider(webView) else { return (nil, "no_registry") }
        // Chrome's webstorePrivate result code; the store shows the installed state instead of
        // re-running the consent prompt for a load that would be a no-op.
        // A disabled copy counts: reinstalling would silently enable it again.
        if registry.context(for: id) != nil || registry.disabledStoredExtensions.contains(where: { $0.id == id }) {
            return ("already_installed", nil)
        }
        do {
            let dir = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: id)
            defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            let review = try ExtensionInstallReview.load(from: dir)
            guard confirmInstall(review) else { return ("user_cancelled", nil) }
            try await registry.load(from: dir)
            return ("", nil)  // "" == success for webstorePrivate.beginInstallWithManifest3
        } catch {
            Self.logger.error("webstore install failed: \(error)")
            return (nil, error.localizedDescription)
        }
    }
}
