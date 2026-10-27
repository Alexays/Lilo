import Foundation

/// Localization for native AppKit surfaces, keyed by the English string (returned as is when untranslated) via the generated `NativeStrings`.
/// The locale (in-app choice mirrored to `UserDefaults`, else the system's) resolves once at first use: a change applies at next launch.
enum Localization {
    private static let overrideKey = "lilo.locale"

    static let locale = resolveLocale(
        override: UserDefaults.lilo.string(forKey: overrideKey), preferredLanguages: Locale.preferredLanguages
    )

    static func resolveLocale(override: String?, preferredLanguages: [String]) -> String {
        if let override, NativeStrings.locales.contains(override) {
            return override
        }
        for language in preferredLanguages {
            let primary = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
            if NativeStrings.locales.contains(primary) { return primary }
        }
        return "en"
    }

    /// Records the language picked in the web UI so native surfaces match it on the next launch.
    static func persistOverride(_ value: String) {
        UserDefaults.lilo.set(value, forKey: overrideKey)
        // AppKit's own strings (Services, open and save panels, Sparkle) follow the app's AppleLanguages.
        if NativeStrings.locales.contains(value) {
            UserDefaults.lilo.set([value], forKey: "AppleLanguages")
        } else {
            UserDefaults.lilo.removeObject(forKey: "AppleLanguages")
        }
    }
}

extension String {
    /// The native-locale translation of this English UI string, or the string itself.
    var localized: String {
        NativeStrings.translate(self, locale: Localization.locale)
    }
}
