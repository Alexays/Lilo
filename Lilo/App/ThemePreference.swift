import AppKit

/// Light / Dark / System appearance override for the whole app. `system` clears any override.
/// Cached so it can re-apply at launch before the chrome web view paints, avoiding a system-appearance flash.
enum ThemePreference: String {
    case system
    case light
    case dark

    init(stored raw: String?) { self = ThemePreference(rawValue: raw ?? "") ?? .system }

    private var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    private static let cacheKey = "lilo.theme"

    @MainActor func apply() {
        NSApp.appearance = appearance
        UserDefaults.lilo.set(rawValue, forKey: Self.cacheKey)
    }

    @MainActor static func applyCachedAtLaunch() {
        ThemePreference(stored: UserDefaults.lilo.string(forKey: cacheKey)).apply()
    }
}
