import XCTest
@testable import Lilo

final class ItalianLocalizationTests: XCTestCase {
    func testItalianSystemLanguagesAndOverrides() {
        for tag in ["it", "it-IT", "IT-ch"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "it", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "it", preferredLanguages: ["fr-FR"]), "it")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["IT-ch"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "IT-ch"]), "it")
    }

    func testItalianNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "it"), "Nuova scheda")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "it"), "Impostazioni…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "it"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "it"), 3), "Spazio 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "it"), "Example Extension"),
                       "Installare Example Extension?")
    }

    func testItalianSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "it"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "it.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("it.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "Questo sito web richiede l'accesso alla fotocamera.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "Apri spazio")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "Apri uno spazio in ${applicationName}")
        #endif
    }

    func testItalianOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("it")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "it")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["it"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
