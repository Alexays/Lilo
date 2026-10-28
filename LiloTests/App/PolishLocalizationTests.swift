import XCTest
@testable import Lilo

final class PolishLocalizationTests: XCTestCase {
    func testPolishSystemLanguagesAndOverrides() {
        for tag in ["pl", "pl-PL", "PL-pl"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "pl", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "pl", preferredLanguages: ["fr-FR"]), "pl")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["PL-pl"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "PL-pl"]), "pl")
    }

    func testPolishNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "pl"), "Nowa karta")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "pl"), "Ustawienia…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "pl"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "pl"), 3), "Przestrzeń 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "pl"), "Example Extension"),
                       "Zainstalować Example Extension?")
    }

    func testPolishSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "pl"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "pl.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("pl.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "Ta witryna prosi o dostęp do kamery.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "Otwórz przestrzeń")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "Otwórz przestrzeń w ${applicationName}")
        #endif
    }

    func testPolishOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("pl")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "pl")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["pl"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
