import XCTest
@testable import Lilo

final class UkrainianLocalizationTests: XCTestCase {
    func testUkrainianSystemLanguagesAndOverrides() {
        for tag in ["uk", "uk-UA", "UK-ua"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "uk", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "uk", preferredLanguages: ["fr-FR"]), "uk")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["UK-ua"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "UK-ua"]), "uk")
    }

    func testUkrainianNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "uk"), "Нова вкладка")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "uk"), "Параметри…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "uk"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "uk"), 3), "Простір 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "uk"), "Example Extension"),
                       "Інсталювати Example Extension?")
    }

    func testUkrainianSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "uk"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "uk.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("uk.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "Цей вебсайт запитує доступ до вашої камери.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "Відкрити простір")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "Відкрити простір у ${applicationName}")
        #endif
    }

    func testUkrainianOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("uk")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "uk")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["uk"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
