import Foundation
import AppKit
import CryptoKit
import Security
import WebKit
import os

struct ExtensionInstallReview: Sendable, Equatable {
    let name: String
    let version: String
    let permissions: [String]
    /// `host_permissions` plus every content-script `matches` pattern: both are granted at load.
    let hostPermissions: [String]

    var message: String {
        let warnings = Self.humanReadableWarnings(permissions: permissions, hostPermissions: hostPermissions)
        guard !warnings.isEmpty else {
            return "This extension requests no special permissions.".localized
        }
        return (["This extension will be able to:".localized] + warnings.map { "- \($0)" })
            .joined(separator: "\n")
    }

    /// Permissions Chrome installs without a warning.
    private static let silentPermissions: Set<String> = [
        "activeTab", "alarms", "contextMenus", "storage", "unlimitedStorage", "scripting", "sidePanel",
        "offscreen", "idle", "power", "menus", "declarativeNetRequestWithHostAccess", "webRequestBlocking"
    ]

    /// Turns raw manifest permission / host-permission strings into Chrome-style human-readable
    /// consent lines, so the install dialog states what access is granted in plain language rather
    /// than opaque tokens. Broad host access is surfaced first and most prominently.
    static func humanReadableWarnings(permissions: [String], hostPermissions: [String]) -> [String] {
        var lines: [String] = []

        let broadPatterns: Set<String> = ["<all_urls>", "*://*/*", "https://*/*", "http://*/*", "*://*"]
        let hasBroadHost = hostPermissions.contains { broadPatterns.contains($0) }
        if hasBroadHost {
            lines.append("Read and change all your data on all websites you visit".localized)
        } else {
            var seen: Set<String> = []
            let shown = hostPermissions.filter { !$0.isEmpty }.map(Self.hostDisplay).filter { seen.insert($0).inserted }
            if !shown.isEmpty {
                let list = shown.prefix(6).joined(separator: ", ")
                lines.append(shown.count > 6
                    ? String(format: "Read and change your data on: %@ and %d more".localized, list, shown.count - 6)
                    : String(format: "Read and change your data on: %@".localized, list))
            }
        }

        let descriptions: [String: String] = [
            "tabs": "See the list and content of your open tabs".localized,
            "history": "Read and erase your browsing history".localized,
            "webNavigation": "Read your browsing history".localized,
            "bookmarks": "Read and change your bookmarks".localized,
            "downloads": "Manage your downloads".localized,
            "cookies": "Read and change cookies for the sites it can access".localized,
            "management": "Manage your other extensions".localized,
            "nativeMessaging": "Communicate with cooperating native apps on your Mac".localized,
            "webRequest": "Observe and modify your network requests".localized,
            "declarativeNetRequest": "Block content on any page".localized,
            "proxy": "Control the browser's proxy settings".localized,
            "privacy": "Change your privacy-related settings".localized,
            "geolocation": "Detect your physical location".localized,
            "clipboardRead": "Read data you copy to the clipboard".localized,
            "clipboardWrite": "Modify data you copy and paste".localized,
            "notifications": "Show you desktop notifications".localized,
            "identity": "Sign you in to a third-party service on its behalf".localized,
            "topSites": "Read a list of your most frequently visited websites".localized,
            "tabGroups": "View and manage your tab groups".localized,
            "debugger": "Access the page debugger backend".localized
        ]
        var unknown: [String] = []
        for permission in permissions where !silentPermissions.contains(permission) {
            if let description = descriptions[permission] {
                lines.append(description)
            } else {
                unknown.append(permission)
            }
        }
        if !unknown.isEmpty {
            lines.append(String(format: "Use other browser features: %@".localized, unknown.joined(separator: ", ")))
        }
        return lines
    }

    private static func hostDisplay(_ pattern: String) -> String {
        URL(string: pattern)?.host ?? pattern
    }

    /// Presents the standard install-consent alert and returns whether the user approved. Shared by
    /// the bridge install path and the "Load unpacked extension..." command so the consent UI is
    /// identical regardless of entry point.
    @MainActor
    func confirmInstall() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: "Install %@?".localized, name)
        alert.informativeText = message
        alert.addButton(withTitle: "Install".localized)
        alert.addButton(withTitle: "Cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks to accept the access an update adds; `self` lists only the additions. A decline keeps the
    /// extension disabled on its current version.
    @MainActor
    func confirmPermissionIncrease() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: "%@ needs new permissions".localized, name)
        let warnings = Self.humanReadableWarnings(permissions: permissions, hostPermissions: hostPermissions)
        alert.informativeText = ([String(format: "The update to version %@ also asks to:".localized, version)] + warnings.map { "- \($0)" })
            .joined(separator: "\n")
        alert.addButton(withTitle: "Accept and Enable".localized)
        alert.addButton(withTitle: "Keep Disabled".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Resolves a Chrome `__MSG_key__` placeholder against `_locales/<default_locale>/messages.json`
    /// (message names are case-insensitive). Returns the input unchanged if it isn't a placeholder or
    /// can't be resolved, so the consent dialog shows the real name (e.g. "LanguageTool") not a token.
    static func resolveLocalizedMessage(_ value: String, defaultLocale: String?, extensionURL: URL) -> String {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__"), let locale = defaultLocale,
              !locale.isEmpty, locale.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return value }
        let key = String(value.dropFirst("__MSG_".count).dropLast("__".count))
        let messagesURL = extensionURL.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let data = try? Data(contentsOf: messagesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return value }
        let entry = (json[key] ?? json.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value) as? [String: Any]
        return (entry?["message"] as? String) ?? value
    }

    static func load(from extensionURL: URL) throws -> ExtensionInstallReview {
        let manifestURL = extensionURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionError.manifestNotFound(manifestURL.path)
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
            try manifest.validate()
            let resolvedName = Self.resolveLocalizedMessage(manifest.name, defaultLocale: manifest.defaultLocale, extensionURL: extensionURL)
            // The name lands in a modal title: one line, bounded like Chrome's 75-character limit.
            let name = String(resolvedName.map { $0.isNewline || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 }.prefix(75))
            var seen: Set<String> = []
            return ExtensionInstallReview(
                name: name,
                version: manifest.version,
                permissions: manifest.permissions ?? [],
                // Every pattern granted at load (ExtensionAccess.baseMatchPatterns).
                hostPermissions: ((manifest.hostPermissions ?? []) + manifest.contentScriptMatches + manifest.externallyConnectableMatches)
                    .filter { seen.insert($0).inserted }
            )
        } catch let error as ExtensionError {
            throw error
        } catch {
            throw ExtensionError.manifestParseError(error.localizedDescription)
        }
    }
}

/// Bridge handler for native UI extension actions (install, uninstall, enable/disable)
@MainActor
final class ExtensionUIBridgeHandler: BridgeHandler, GapHandler {
    private static let logger = Logger(liloCategory: "extension-bridge-handler")

    /// The chrome UI's registry: the profile its window shows. Absent on the extension-facing instance.
    private let extensionRegistryProvider: (@MainActor () -> ProfileExtensionRegistry?)?
    var installReviewHandler: ((ExtensionInstallReview) -> Bool)?

    /// Emitted when a UI-initiated enable/disable/uninstall settles, so the panel can resolve its
    /// pending state crisply (success or failure) instead of waiting on a timeout. `(id, action,
    /// success, error)`.
    var onActionCompleted: ((String, String, Bool, String?) -> Void)?

    /// Invoked when the UI asks to load an unpacked extension; the host presents a folder picker.
    var onLoadUnpacked: (() -> Void)?

    /// The registry of another existing profile, built (not restored) through the profile context cache.
    var profileRegistryProvider: (@MainActor (UUID) -> ProfileExtensionRegistry?)?
    /// Hands the settings the rows of a profile its window does not show; `live` once its registry is restored.
    var onProfileExtensions: ((_ profileId: UUID, _ rows: [[String: Any]], _ live: Bool) -> Void)?

    private func settle(id: String, action: String, _ result: Any?) -> Any? {
        let error = (result as? BridgeError)?.message
        onActionCompleted?(id, action, error == nil, error)
        return result
    }

    let handledActions: Set<String> = [
        "installExtension",
        "loadUnpackedExtension",
        "enableExtension",
        "disableExtension",
        "uninstallExtension",
        "setExtensionSiteAccess",
        "setExtensionPrivateAccess",
        "setExtensionUserScripts",
        "setExtensionCommandShortcut",
        "acceptExtensionHostAccessRequest",
        "checkExtensionUpdates",
        "updateExtension",
        "openExtensionPopup",
        "updateExtensionPopupAnchor",
        "getProfileExtensions"
    ]

    /// Extensions reach only these; install and uninstall stay on the chrome UI bridge.
    let gapActions: Set<String> = ["action.openPopup", "runtime.extensionViews"]

    init(extensionRegistryProvider: (@MainActor () -> ProfileExtensionRegistry?)? = nil) {
        self.extensionRegistryProvider = extensionRegistryProvider
    }

    private var extensionRegistry: ProfileExtensionRegistry? {
        extensionRegistryProvider?()
    }

    /// The profile a settings message names when the window shows another one.
    private func otherProfileId(of message: BridgeMessage) -> UUID? {
        guard let profileId = message.uuid("profileId"), profileId != extensionRegistry?.profileId else { return nil }
        return profileId
    }

    /// The registry a settings action applies to: the window's, or the named profile's, restored first
    /// (as showing it in a window would) so it knows every installed extension before one changes.
    private func targetRegistry(for message: BridgeMessage) async -> ProfileExtensionRegistry? {
        guard let profileId = otherProfileId(of: message) else { return extensionRegistry }
        guard let registry = profileRegistryProvider?(profileId) else { return nil }
        await registry.restore()
        return registry
    }

    /// Stored rows until the profile's registry is restored, so listing a profile no window shows starts none of its extensions.
    private func sendProfileExtensions(_ profileId: UUID, live: Bool) async {
        guard let registry = profileRegistryProvider?(profileId) else { return }
        if live || registry.isRestored {
            await registry.restore()
            onProfileExtensions?(profileId, registry.extensionBridgePayloads(activeTab: nil), true)
        } else {
            onProfileExtensions?(profileId, await registry.storedBridgePayloads(), false)
        }
    }

    /// `action.openPopup` opens the caller's popup, in the caller's profile; `runtime.extensionViews`
    /// lists its pages on screen outside tabs.
    func handle(_ call: GapCall) async -> Any? {
        guard call.action == "runtime.extensionViews" else {
            return await openPopup(extensionId: call.extensionId, anchorRect: nil, registry: call.registry)
        }
        guard let context = call.registry.context(for: call.extensionId) else { return [] }
        return call.registry.delegate.extensionViews(of: context).map { ["contextType": $0.contextType, "url": $0.url.absoluteString] }
    }

    func handle(message: BridgeMessage) async -> Any? {
        if message.action == "getProfileExtensions" {
            if let profileId = otherProfileId(of: message) { await sendProfileExtensions(profileId, live: message.bool("live")) }
            return nil
        }
        let result = await handleAction(message)
        // Nothing tells this window about another profile's changes: its settings get the rows again.
        if let profileId = otherProfileId(of: message) { await sendProfileExtensions(profileId, live: true) }
        return result
    }

    private func handleAction(_ message: BridgeMessage) async -> Any? {
        switch message.action {
        case "installExtension":
            return await handleInstallExtension(message: message)
        case "loadUnpackedExtension":
            onLoadUnpacked?()
            return ["success": true]
        case "enableExtension":
            return await handleEnableExtension(message: message)
        case "disableExtension":
            return await handleDisableExtension(message: message)
        case "uninstallExtension":
            return await handleUninstallExtension(message: message)
        case "setExtensionSiteAccess":
            return await handleSetExtensionSiteAccess(message: message)
        case "setExtensionPrivateAccess":
            guard let id = message.string("id"), let registry = await targetRegistry(for: message) else { return BridgeError("Missing extension id") }
            await registry.access.setPrivateAccess(extensionId: id, allowed: message.bool("allowed"))
            return ["success": true]
        case "setExtensionUserScripts":
            guard let id = message.string("id"), let registry = await targetRegistry(for: message) else { return BridgeError("Missing extension id") }
            await registry.setUserScriptsAllowed(extensionId: id, allowed: message.bool("allowed"))
            return ["success": true]
        case "acceptExtensionHostAccessRequest":
            guard let id = message.string("id"), let registry = extensionRegistry else { return BridgeError("Missing extension id") }
            await registry.access.acceptHostAccessRequest(extensionId: id, on: registry.delegate.windowAdapter?.visibleActiveAdapter)
            return ["success": true]
        case "setExtensionCommandShortcut":
            guard let id = message.string("id"), let command = message.string("command"), let registry = await targetRegistry(for: message) else {
                return BridgeError("Missing extension command")
            }
            let key = message.string("key").flatMap { $0.isEmpty ? nil : $0 }
            let modifiers = NSEvent.ModifierFlags(rawValue: (message.payload["modifiers"] as? NSNumber)?.uintValue ?? 0)
            await registry.access.setCommandShortcut(extensionId: id, commandId: command, key: key, modifiers: modifiers)
            return ["success": true]
        case "checkExtensionUpdates":
            await extensionRegistry?.updater.checkForUpdates()
            return ["success": true]
        case "updateExtension":
            guard let id = message.string("id") else { return BridgeError("Missing extension id") }
            guard let registry = await targetRegistry(for: message) else {
                return settle(id: id, action: "update", BridgeError("Extension registry not available"))
            }
            let succeeded = await registry.updater.updateExtension(extensionId: id)
            return settle(id: id, action: "update", succeeded ? ["success": true] : BridgeError("Extension update failed"))
        case "openExtensionPopup":
            guard let id = message.string("id") else { return nil }
            if let registry = extensionRegistry, let window = registry.delegate.windowController,
               registry.toggleSidePanelOnActionClick?(id, window) == true {
                return nil
            }
            extensionRegistry?.noteUserGesture(extensionId: id)
            return await openPopup(extensionId: id, anchorRect: Self.anchorRect(from: message), registry: extensionRegistry)
        case "updateExtensionPopupAnchor":
            return handleUpdateExtensionPopupAnchor(message: message)
        default:
            return BridgeError("Unknown action: \(message.action)")
        }
    }

    // MARK: - Install

    private func handleInstallExtension(message: BridgeMessage) async -> Any? {
        let path = message.string("path") ?? ""
        if path.hasPrefix("file://"), let fileURL = URL(string: path) {
            return await installLocalExtension(from: fileURL)
        } else if let webURL = URL(string: path), webURL.scheme == "https" || webURL.scheme == "http" {
            guard webURL.scheme == "https" else {
                return BridgeError("Chrome Web Store installs require HTTPS")
            }
            return await installFromChromeWebStore(storeURL: webURL)
        } else {
            return await installLocalExtension(from: URL(fileURLWithPath: path))
        }
    }

    private func installLocalExtension(from url: URL) async -> Any? {
        Self.logger.info("Loading extension from: \(url.path)")
        guard let registry = extensionRegistry else { return BridgeError("Extension registry not available") }
        do {
            let review = try ExtensionInstallReview.load(from: url)
            guard requestInstallApproval(for: review) else {
                return BridgeError("Extension install cancelled")
            }
            try await registry.load(from: url)
            return ["success": true]
        } catch {
            Self.logger.error("Extension load failed: \(error)")
            return BridgeError(error.localizedDescription)
        }
    }

    private func requestInstallApproval(for review: ExtensionInstallReview) -> Bool {
        installReviewHandler?(review) ?? review.confirmInstall()
    }

    // MARK: - Chrome Web Store Install

    private func installFromChromeWebStore(storeURL: URL) async -> Any? {
        guard let extensionId = ChromeWebStoreInstaller.extensionId(from: storeURL) else {
            return BridgeError("Not a Chrome Web Store extension URL")
        }
        Self.logger.info("Installing CWS extension: \(extensionId, privacy: .public)")
        do {
            let extractedDir = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: extensionId)
            defer { try? FileManager.default.removeItem(at: extractedDir.deletingLastPathComponent()) }
            return settle(id: extensionId, action: "install", await installLocalExtension(from: extractedDir))
        } catch {
            Self.logger.error("CWS install failed: \(error)")
            return settle(id: extensionId, action: "install", BridgeError(error.localizedDescription))
        }
    }

    // MARK: - Enable, Site Access, Disable, Uninstall

    private func handleEnableExtension(message: BridgeMessage) async -> Any? {
        guard let id = message.string("id") else { return BridgeError("Missing extension id") }
        guard let registry = await targetRegistry(for: message) else {
            return settle(id: id, action: "enable", BridgeError("Extension registry not available"))
        }
        do {
            try await registry.enable(extensionId: id)
            return settle(id: id, action: "enable", ["success": true])
        } catch {
            return settle(id: id, action: "enable", BridgeError(error.localizedDescription))
        }
    }

    /// An empty `hosts` restores the extension's manifest hosts; anything else restricts it.
    private func handleSetExtensionSiteAccess(message: BridgeMessage) async -> Any? {
        guard let id = message.string("id") else { return BridgeError("Missing extension id") }
        guard let registry = await targetRegistry(for: message) else {
            return settle(id: id, action: "siteAccess", BridgeError("Extension registry not available"))
        }
        await registry.access.setSiteAccess(extensionId: id, hosts: message.payload["hosts"] as? [String] ?? [])
        return settle(id: id, action: "siteAccess", ["success": true])
    }

    private func handleDisableExtension(message: BridgeMessage) async -> Any? {
        guard let id = message.string("id") else { return BridgeError("Missing extension id") }
        guard let registry = await targetRegistry(for: message) else {
            return settle(id: id, action: "disable", BridgeError("Extension registry not available"))
        }
        await registry.disable(extensionId: id)
        return settle(id: id, action: "disable", ["success": true])
    }

    private func handleUninstallExtension(message: BridgeMessage) async -> Any? {
        guard let id = message.string("id") else { return BridgeError("Missing extension id") }
        guard let registry = await targetRegistry(for: message) else {
            return settle(id: id, action: "uninstall", BridgeError("Extension registry not available"))
        }
        await registry.unload(extensionId: id)
        return settle(id: id, action: "uninstall", ["success": true])
    }

    // MARK: - Open Popup

    // Nil when the message carries no coordinates;
    // a fabricated zero rect would anchor the popup to the window's top-left corner.
    static func anchorRect(from message: BridgeMessage) -> NSRect? {
        guard let x = message.cgFloat("x"), let y = message.cgFloat("y") else { return nil }
        return NSRect(
            x: x,
            y: y,
            width: message.cgFloat("width") ?? 0,
            height: message.cgFloat("height") ?? 0
        )
    }

    private func handleUpdateExtensionPopupAnchor(message: BridgeMessage) -> [String: Any]? {
        guard let id = message.string("id") else { return nil }
        guard let registry = extensionRegistry else { return nil }
        guard let rect = Self.anchorRect(from: message) else { return nil }

        registry.delegate.setPopupAnchorRect(rect, for: id)
        return nil
    }

    /// A nil `anchorRect` (chrome.action.openPopup) anchors the popup on the stored icon rect.
    private func openPopup(extensionId id: String, anchorRect: NSRect?, registry: ProfileExtensionRegistry?) async -> [String: Any]? {
        guard let registry, registry.context(for: id) != nil else { return nil }

        registry.delegate.closeOpenActionPopups(reason: "toolbar open", extensionId: id)
        let actionTabAdapter: TabExtensionAdapter?
        if let tabManager = registry.delegate.tabManager,
           let activeOpenTabId = tabManager.activeOpenTabId {
            actionTabAdapter = tabManager.tabAdapter(for: activeOpenTabId)
        } else {
            actionTabAdapter = nil
        }
        if let actionTabAdapter {
            registry.delegate.windowAdapter?.activeAdapter = actionTabAdapter
        }
        if let anchorRect {
            registry.delegate.setPopupAnchorRect(anchorRect, for: id)
        }
        registry.delegate.pendingPopupAnchorRect = anchorRect
        await registry.backgrounds.ensureResponsive(id)
        // Re-fetch after the await: a stale worker is reloaded into a BRAND-NEW context, and performing
        // the action on the torn-down one would present the popup against the dead worker (a hang).
        guard let context = registry.context(for: id) else { return nil }
        context.performAction(for: actionTabAdapter)
        return nil
    }
}

enum ExtensionArchiveSafety {
    static func isSafeZipEntry(_ entry: String) -> Bool {
        guard !entry.isEmpty,
              !entry.hasPrefix("/"),
              !entry.hasPrefix("\\"),
              !entry.contains("\0") else {
            return false
        }
        let parts = entry.split { $0 == "/" || $0 == "\\" }.map(String.init)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Chrome `[a-p]` id derived from a SubjectPublicKeyInfo (SHA-256, first 16 bytes, nibble-encoded).
    static func chromeExtensionId(forPublicKey publicKey: Data) -> String {
        chromeExtensionId(fromRawId: Data(SHA256.hash(data: publicKey).prefix(16)))
    }

    /// Chrome `[a-p]` id from an already-hashed 16-byte crx id (as carried in `SignedData.crx_id`).
    static func chromeExtensionId(fromRawId rawId: Data) -> String {
        let alphabet = Array("abcdefghijklmnop")
        return rawId.prefix(16).flatMap { byte in
            [alphabet[Int(byte >> 4)], alphabet[Int(byte & 0x0f)]]
        }.map(String.init).joined()
    }

    /// A single CRX3 `AsymmetricKeyProof`: the signer's SubjectPublicKeyInfo and its signature over the
    /// reconstructed payload. `isRSA` selects `sha256_with_rsa` (field 2) vs `sha256_with_ecdsa`
    /// (field 3) so the matching SecKey type and algorithm are used.
    private struct CRXProof {
        let publicKey: Data
        let signature: Data
        let isRSA: Bool
    }

    /// Verifies CRX3 as Chromium's `crx_file` does: a proof must verify over the signed data and derive `expectedExtensionId`, and
    /// `SignedData.crx_id` must name it too (blocks proof transplant). `requirePublisherProof` also demands the Web Store key's proof.
    static func verifyCRX3(header: Data, archive: Data, expectedExtensionId: String, requirePublisherProof: Bool) -> Bool {
        let expected = expectedExtensionId.lowercased()
        let (proofs, signedHeaderData) = parseCRXHeader(header)
        guard let signedHeaderData else { return false }

        var crxId: Data?
        parseLengthDelimitedFields(in: signedHeaderData) { field, value in
            if field == 1 { crxId = Data(value) }
        }
        guard let crxId, crxId.count == 16,
              chromeExtensionId(fromRawId: crxId) == expected else { return false }

        let message = signedPayload(signedHeaderData: signedHeaderData, archive: archive)
        if requirePublisherProof {
            guard proofs.contains(where: {
                Data(SHA256.hash(data: $0.publicKey)) == webStorePublisherKeyHash && verify(proof: $0, over: message)
            }) else { return false }
        }
        for proof in proofs where chromeExtensionId(forPublicKey: proof.publicKey) == expected {
            if verify(proof: proof, over: message) { return true }
        }
        return false
    }

    /// SHA-256 of the Web Store's "ecdsa_2017_public" publisher SPKI (Chromium `kPublisherKeyHash`).
    static let webStorePublisherKeyHash = Data([
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe,
        0x24, 0x97, 0xcc, 0x9b, 0x04, 0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2,
        0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf
    ])

    /// Reconstructs the exact byte string CRX3 proofs are computed over.
    private static func signedPayload(signedHeaderData: Data, archive: Data) -> Data {
        var message = Data("CRX3 SignedData\u{0}".utf8) // 16-byte context, trailing NUL included
        var length = UInt32(signedHeaderData.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(signedHeaderData)
        message.append(archive)
        return message
    }

    private static func verify(proof: CRXProof, over message: Data) -> Bool {
        guard let keyBytes = subjectPublicKeyBytes(fromSPKI: proof.publicKey) else { return false }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: proof.isRSA ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        let algorithm: SecKeyAlgorithm = proof.isRSA
            ? .rsaSignatureMessagePKCS1v15SHA256
            : .ecdsaSignatureMessageX962SHA256
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyBytes as CFData, attributes as CFDictionary, &error) else {
            return false
        }
        return SecKeyVerifySignature(key, algorithm, message as CFData, proof.signature as CFData, &error)
    }

    private static func parseCRXHeader(_ header: Data) -> (proofs: [CRXProof], signedHeaderData: Data?) {
        var proofs: [CRXProof] = []
        var signedHeaderData: Data?
        parseLengthDelimitedFields(in: header) { fieldNumber, value in
            switch fieldNumber {
            case 2, 3:
                var publicKey: Data?
                var signature: Data?
                parseLengthDelimitedFields(in: value) { nestedField, nestedValue in
                    if nestedField == 1 {
                        publicKey = Data(nestedValue)
                    } else if nestedField == 2 {
                        signature = Data(nestedValue)
                    }
                }
                if let publicKey, let signature {
                    proofs.append(CRXProof(publicKey: publicKey, signature: signature, isRSA: fieldNumber == 2))
                }
            case 10000:
                signedHeaderData = Data(value)
            default:
                break
            }
        }
        return (proofs, signedHeaderData)
    }

    /// The SubjectPublicKey bits of a DER SPKI (PKCS#1 for RSA, the raw X9.63 point for P-256), as `SecKeyCreateWithData` expects.
    /// nil on malformed input.
    private static func subjectPublicKeyBytes(fromSPKI spki: Data) -> Data? {
        let data = Data(spki) // normalise to a 0-based buffer for integer indexing
        var index = 0
        guard let outer = readDER(data, at: &index), outer.tag == 0x30 else { return nil }
        let inner = Data(outer.value)
        var innerIndex = 0
        guard let algorithm = readDER(inner, at: &innerIndex), algorithm.tag == 0x30 else { return nil }
        guard let bitString = readDER(inner, at: &innerIndex), bitString.tag == 0x03 else { return nil }
        var payload = Data(bitString.value)
        guard payload.first == 0x00 else { return nil } // leading unused-bits octet must be zero
        payload.removeFirst()
        return payload
    }

    /// Reads one DER TLV starting at `index` (0-based into `data`, whose startIndex must be 0), advancing
    /// `index` past it. Supports short and up-to-4-byte long-form lengths.
    private static func readDER(_ data: Data, at index: inout Int) -> (tag: UInt8, value: Data)? {
        guard index < data.count else { return nil }
        let tag = data[index]; index += 1
        guard index < data.count else { return nil }
        var length = Int(data[index]); index += 1
        if length & 0x80 != 0 {
            let byteCount = length & 0x7f
            guard byteCount > 0, byteCount <= 4, index + byteCount <= data.count else { return nil }
            length = 0
            for _ in 0..<byteCount { length = (length << 8) | Int(data[index]); index += 1 }
        }
        guard index + length <= data.count else { return nil }
        let value = data.subdata(in: index ..< index + length)
        index += length
        return (tag, value)
    }

    private static func parseLengthDelimitedFields(in data: Data, visit: (Int, Data) -> Void) {
        var index = data.startIndex
        while index < data.endIndex {
            guard let key = readVarint(data, index: &index) else { return }
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)
            switch wireType {
            case 0:
                guard readVarint(data, index: &index) != nil else { return }
            case 1:
                guard skip(8, in: data, index: &index) else { return }
            case 2:
                guard let length = readVarint(data, index: &index),
                      length <= UInt64(data.endIndex - index) else { return }
                let end = index + Int(length)
                visit(fieldNumber, data[index..<end])
                index = end
            case 5:
                guard skip(4, in: data, index: &index) else { return }
            default:
                return
            }
        }
    }

    private static func readVarint(_ data: Data, index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private static func skip(_ count: Int, in data: Data, index: inout Data.Index) -> Bool {
        guard count <= data.endIndex - index else { return false }
        index += count
        return true
    }
}
