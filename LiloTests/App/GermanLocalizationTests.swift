import XCTest
@testable import Lilo

final class GermanLocalizationTests: XCTestCase {
    func testGermanSystemLanguagesAndOverrides() {
        for tag in ["de", "de-DE", "DE-at", "de-CH"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "de", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "de", preferredLanguages: ["fr-FR"]), "de")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["de-CH"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "de-CH"]), "de")
    }

    func testGermanNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "de"), "Neuer Tab")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "de"), "Einstellungen…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "de"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "de"), 3), "Space 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "de"), "Example Extension"),
                       "Example Extension installieren?")
    }

    func testGermanSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "de"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "de.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("de.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "Diese Website möchte auf deine Kamera zugreifen.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "Space öffnen")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "Space in ${applicationName} öffnen")
        #endif
    }

    func testGermanOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("de")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "de")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["de"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
