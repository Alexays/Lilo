import XCTest
@testable import Lilo

final class LocalizationTests: XCTestCase {
    func testNativeLocaleHonorsTheOverrideAndResolvesRegionalTags() {
        XCTAssertEqual(Localization.resolveLocale(override: "es", preferredLanguages: ["fr-FR"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["es-ES"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["es-MX"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["ES-419"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["fr-CA"]), "fr")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["de-DE", "es-ES"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["de-DE"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: []), "en")
    }

    func testSpanishNativeStringsAndSystemPromptsShipInTheApp() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "es"), "Nueva pestaña")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "es"), "Unknown test string")
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = Bundle.main.url(forResource: resource, withExtension: "strings", subdirectory: nil, localization: "es")
            XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, "es.lproj", resource)
        }
        #endif
    }

    func testSpanishOverrideAlsoSelectsTheLanguageOfSystemPanels() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("es")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "es")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["es"])

        Localization.persistOverride("")
        // A normal lookup falls back to macOS's global language list once the override is removed.
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
