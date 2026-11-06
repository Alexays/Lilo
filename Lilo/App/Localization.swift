import Foundation

/// Localization for native AppKit surfaces, keyed by the English string (returned as is when untranslated) via the generated `NativeStrings`.
/// The locale (in-app choice mirrored to `UserDefaults`, else the system's) resolves once at first use: a change applies at next launch.
enum Localization {
    private static let overrideKey = "lilo.locale"

    static let locale = unsafe resolveLocale(
        override: UserDefaults.lilo.string(forKey: overrideKey), preferredLanguages: Locale.preferredLanguages
    )

    static func resolveLocale(override: String?, preferredLanguages: [String]) -> String {
        if let override, NativeStrings.locales.contains(override) {
            return override
        }
        for language in preferredLanguages {
            let parts = language.lowercased().split(separator: "-")
            let primary = parts.first.map(String.init) ?? ""
            if primary == "zh" {
                if let script = parts.first(where: { $0 == "hans" || $0 == "hant" }) {
                    return script == "hans" ? "zh-Hans" : "zh-Hant"
                } else {
                    return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
                }
            } else if primary == "pt" {
                return "pt-BR"
            } else if NativeStrings.locales.contains(primary) {
                return primary
            }
        }
        return "en"
    }

    /// The form of the plural entry `key` (its English "other" form) that the CLDR rules of `locale` pick for `count`.
    static func plural(_ key: String, count: Int, locale: String) -> String {
        let forms = NativeStrings.plurals(key, locale: locale)
        let mod10 = count % 10, mod100 = count % 100
        let few = (2...4).contains(mod10) && !(12...14).contains(mod100)
        let category = switch locale {
        case "ja", "ko", "zh-Hans", "zh-Hant": "other"
        case "fr", "pt-BR": count <= 1 ? "one" : "other"
        case "ru", "uk": mod10 == 1 && mod100 != 11 ? "one" : few ? "few" : "many"
        case "pl": count == 1 ? "one" : few ? "few" : "many"
        default: count == 1 ? "one" : "other"
        }
        return forms[category] ?? forms["other"] ?? key
    }

    /// Records the language picked in the web UI so native surfaces match it on the next launch.
    static func persistOverride(_ value: String) {
        unsafe UserDefaults.lilo.set(value, forKey: overrideKey)
        // AppKit's own strings (Services, open and save panels, Sparkle) follow the app's AppleLanguages.
        if NativeStrings.locales.contains(value) {
            unsafe UserDefaults.lilo.set([value], forKey: "AppleLanguages")
        } else {
            unsafe UserDefaults.lilo.removeObject(forKey: "AppleLanguages")
        }
    }
}

extension String {
    /// The native-locale translation of this English UI string, or the string itself.
    var localized: String {
        NativeStrings.translate(self, locale: Localization.locale)
    }

    /// The native-locale form of this plural UI string, keyed by its English "other" form, that fits `count`.
    func localized(count: Int) -> String {
        Localization.plural(self, count: count, locale: Localization.locale)
    }
}
