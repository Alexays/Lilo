import Foundation

/// Localization for native AppKit surfaces, keyed by the English string (returned as is when untranslated) via the generated `NativeStrings`.
/// The locale (in-app choice mirrored to `UserDefaults`, else the system's) resolves once at first use: a change applies at next launch.
enum Localization {
    private static let overrideKey = "lilo.locale"

    static let locale: String = {
        if let override = UserDefaults.lilo.string(forKey: overrideKey), override == "en" || override == "fr" {
            return override
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("fr") ? "fr" : "en"
    }()

    /// Records the language picked in the web UI so native surfaces match it on the next launch.
    static func persistOverride(_ value: String) {
        UserDefaults.lilo.set(value, forKey: overrideKey)
        // AppKit's own strings (Services, open and save panels, Sparkle) follow the app's AppleLanguages.
        if value == "en" || value == "fr" {
            UserDefaults.lilo.set([value], forKey: "AppleLanguages")
        } else {
            UserDefaults.lilo.removeObject(forKey: "AppleLanguages")
        }
    }
}

extension String {
    /// The native-locale translation of this English UI string, or the string itself.
    var localized: String {
        Localization.locale == "fr" ? (NativeStrings.fr[self] ?? self) : self
    }
}
