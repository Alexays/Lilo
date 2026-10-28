import XCTest
@testable import Lilo

final class TurkishLocalizationTests: XCTestCase {
    func testTurkishSystemLanguagesAndOverrides() {
        for tag in ["tr", "tr-TR", "TR-tr"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "tr", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "tr", preferredLanguages: ["fr-FR"]), "tr")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["TR-tr"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "TR-tr"]), "tr")
    }

    func testTurkishNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "tr"), "Yeni Sekme")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "tr"), "Ayarlar…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "tr"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "tr"), 3), "Alan 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "tr"), "Example Extension"),
                       "Example Extension yüklensin mi?")
    }

    func testTurkishSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "tr"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "tr.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("tr.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "Bu web sitesi kameranıza erişmek istiyor.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "Alan Aç")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "${applicationName} uygulamasında bir alan aç")
        #endif
    }

    func testTurkishOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("tr")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "tr")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["tr"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
