import AppKit
import Foundation

/// chrome.fontSettings. WebKit takes the standard and fixed-pitch families of the global script and
/// the three sizes, which apply to the profile's pages; other families and scripts are kept and
/// reported as in Chrome but render with WebKit's own choice.
@MainActor
final class FontSettingsBridgeHandler: GapHandler {
    /// What the profile's extensions set on WebKit's preferences; nil leaves WebKit's default.
    struct Overrides: Equatable {
        var standardFamily: String?
        var fixedFamily: String?
        var defaultSize: Int?
        var defaultFixedSize: Int?
        var minimumSize: Int?
    }

    private struct Size {
        let key: String
        let event: String
        let defaultValue: () -> Int
    }

    private static let sizes: [String: Size] = [
        "DefaultFontSize": Size(key: "fontSettings.defaultFontSize", event: "onDefaultFontSizeChanged") { 16 },
        "DefaultFixedFontSize": Size(key: "fontSettings.defaultFixedFontSize", event: "onDefaultFixedFontSizeChanged") { 13 },
        "MinimumFontSize": Size(key: "fontSettings.minimumFontSize", event: "onMinimumFontSizeChanged") { Int(WKEngineFactory.minimumFontSize) }
    ]
    private static let families: Set<String> = ["standard", "sansserif", "serif", "fixed", "cursive", "fantasy", "math"]
    /// Chrome's Mac defaults for the global script, which WebKit shares; other scripts default to "".
    private static let defaultFonts = [
        "standard": "Times", "serif": "Times", "sansserif": "Helvetica", "fixed": "Courier",
        "cursive": "Apple Chancery", "fantasy": "Papyrus", "math": "STIX Two Math"
    ]
    private static let fontPrefix = "fontSettings.font."

    let gapActions: Set<String> = Set(
        ["fontSettings.getFont", "fontSettings.setFont", "fontSettings.clearFont", "fontSettings.getFontList"]
            + sizes.keys.flatMap { name in ["get", "set", "clear"].map { "fontSettings.\($0)\(name)" } }
    )

    private let settingsProvider: (ProfileExtensionRegistry) -> ExtensionSettingsStore?
    /// Applies a profile's new overrides to its pages.
    var onOverridesChanged: ((ProfileExtensionRegistry) -> Void)?
    /// Effective values per profile, as last announced.
    private var effective: [UUID: [String: AnyHashable]] = [:]
    nonisolated(unsafe) private var observers: [Any] = []

    init(settingsProvider: @escaping (ProfileExtensionRegistry) -> ExtensionSettingsStore?) {
        self.settingsProvider = settingsProvider
        observers = [Notification.Name.extensionRuntimeLoaded, .extensionDidUnload].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let registry = note.object as? ProfileExtensionRegistry else { return }
                MainActor.assumeIsolated { self?.refresh(registry) }
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let settings = settingsProvider(call.registry) else { return BridgeError("Extension settings unavailable") }
        let loadedIds = call.registry.loadedExtensions.map(\.id)
        let method = call.action.dropFirst("fontSettings.".count)

        if method == "getFontList" {
            let manager = NSFontManager.shared
            return manager.availableFontFamilies
                .map { ["fontId": $0, "displayName": manager.localizedName(forFamily: $0, face: nil)] }
                .sorted { $0["displayName"]!.localizedStandardCompare($1["displayName"]!) == .orderedAscending }
        }

        if method.hasSuffix("Font") {
            let family = call.string("genericFamily") ?? ""
            guard Self.families.contains(family) else { return BridgeError("Invalid generic family.") }
            let script = call.string("script") ?? "Zyyy"
            // The key embeds the script, so anything but an ISO 15924 code would make it unparsable.
            guard script.utf8.count == 4, script.allSatisfy({ $0.isASCII && $0.isLetter }) else { return BridgeError("Invalid script.") }
            let key = "\(Self.fontPrefix)\(family).\(script)"
            switch method {
            case "getFont":
                return [
                    "fontId": settings.controller(of: key, among: loadedIds).flatMap { settings.value(key, extensionId: $0) }
                        ?? (script == "Zyyy" ? Self.defaultFonts[family] ?? "" : ""),
                    "levelOfControl": settings.levelOfControl(of: key, for: call.extensionId, among: loadedIds)
                ]
            case "setFont":
                let fontId = call.string("fontId") ?? ""
                guard Self.isValidFontName(fontId) else { return BridgeError("Invalid font ID.") }
                settings.set(key, extensionId: call.extensionId, to: fontId)
            default:
                settings.set(key, extensionId: call.extensionId, to: nil)
            }
            refresh(call.registry)
            return nil
        }

        let verb = method.prefix { $0.isLowercase }
        guard let size = Self.sizes[String(method.dropFirst(verb.count))] else { return nil }
        switch verb {
        case "get":
            return [
                "pixelSize": settings.controller(of: size.key, among: loadedIds).flatMap { settings.value(size.key, extensionId: $0) } ?? size.defaultValue(),
                "levelOfControl": settings.levelOfControl(of: size.key, for: call.extensionId, among: loadedIds)
            ]
        case "set":
            guard let pixelSize = call.int("pixelSize") else { return BridgeError("Invalid pixel size.") }
            settings.set(size.key, extensionId: call.extensionId, to: pixelSize)
        default:
            settings.set(size.key, extensionId: call.extensionId, to: nil)
        }
        refresh(call.registry)
        return nil
    }

    /// Chrome's IsValidFontName: up to 256 bytes of letters, digits, non-ASCII and ` -_.+`.
    private static func isValidFontName(_ name: String) -> Bool {
        name.utf8.count <= 256 && name.unicodeScalars.allSatisfy { scalar in
            !scalar.isASCII || CharacterSet.alphanumerics.contains(scalar) || " -_.+".unicodeScalars.contains(scalar)
        }
    }

    func overrides(for registry: ProfileExtensionRegistry) -> Overrides {
        guard let settings = settingsProvider(registry) else { return Overrides() }
        let loadedIds = registry.loadedExtensions.map(\.id)
        func value<T>(_ key: String) -> T? {
            settings.controller(of: key, among: loadedIds).flatMap { settings.value(key, extensionId: $0) as? T }
        }
        return Overrides(
            standardFamily: value("\(Self.fontPrefix)standard.Zyyy"),
            fixedFamily: value("\(Self.fontPrefix)fixed.Zyyy"),
            defaultSize: value(Self.sizes["DefaultFontSize"]!.key),
            defaultFixedSize: value(Self.sizes["DefaultFixedFontSize"]!.key),
            minimumSize: value(Self.sizes["MinimumFontSize"]!.key)
        )
    }

    /// Recomputes the profile's effective values, fires Chrome's change events for those that moved,
    /// and reapplies the overrides. Also run for a change of Lilo's own minimum font size.
    func refresh(_ registry: ProfileExtensionRegistry) {
        guard let settings = settingsProvider(registry) else { return }
        let loadedIds = registry.loadedExtensions.map(\.id)
        var now: [String: AnyHashable] = [:]
        for key in settings.keys(withPrefix: Self.fontPrefix) {
            if let id = settings.controller(of: key, among: loadedIds) { now[key] = settings.value(key, extensionId: id) as? AnyHashable }
        }
        for size in Self.sizes.values {
            now[size.key] = settings.controller(of: size.key, among: loadedIds).flatMap { settings.value(size.key, extensionId: $0) as? AnyHashable }
                ?? AnyHashable(size.defaultValue())
        }
        let previous = effective[registry.profileId]
        effective[registry.profileId] = now
        guard previous != now else { return }
        onOverridesChanged?(registry)
        // The first values computed for a profile are its launch state, which Chrome does not announce.
        guard let previous else { return }
        let listeners = registry.extensionIds(withPermission: "fontSettings")
        for key in Set(previous.keys).union(now.keys) where previous[key] != now[key] {
            var details: [String: Any]
            let event: String
            if key.hasPrefix(Self.fontPrefix) {
                // A persisted key is not trusted to parse: a malformed one announces nothing.
                let parts = key.dropFirst(Self.fontPrefix.count).split(separator: ".")
                guard parts.count == 2, let defaultFont = Self.defaultFonts[String(parts[0])] else { continue }
                let family = String(parts[0]), script = String(parts[1])
                event = "onFontChanged"
                details = ["fontId": now[key]?.base ?? (script == "Zyyy" ? defaultFont : ""), "genericFamily": family, "script": script]
            } else {
                let size = Self.sizes.values.first { $0.key == key }!
                event = size.event
                details = ["pixelSize": now[key]!.base]
            }
            for id in listeners {
                details["levelOfControl"] = settings.levelOfControl(of: key, for: id, among: loadedIds)
                registry.gapEvents.emit("fontSettings", event, args: [details], to: [id])
            }
        }
    }
}
