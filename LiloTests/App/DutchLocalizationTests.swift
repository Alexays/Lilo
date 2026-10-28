import XCTest
@testable import Lilo

final class DutchLocalizationTests: XCTestCase {
    func testDutchSystemLanguagesAndOverrides() {
        for tag in ["nl", "nl-NL", "NL-be"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "nl", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "nl", preferredLanguages: ["fr-FR"]), "nl")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["NL-be"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "NL-be"]), "nl")
    }

    func testDutchNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "nl"), "Nieuw tabblad")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "nl"), "Instellingen…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "nl"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "nl"), 3), "Ruimte 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "nl"), "Example Extension"),
                       "Example Extension installeren?")
    }

    func testDutchSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "nl"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "nl.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("nl.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "Deze website vraagt toegang tot je camera.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "Open ruimte")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "Open een ruimte in ${applicationName}")
        #endif
    }

    func testDutchOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("nl")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "nl")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["nl"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
