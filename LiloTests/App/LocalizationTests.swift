import XCTest
@testable import Lilo

final class LocalizationTests: XCTestCase {
    func testNativeLocaleHonorsOverridesAndRegionalTags() {
        XCTAssertEqual(Localization.resolveLocale(override: "es", preferredLanguages: ["fr-FR"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["es-ES"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["es-MX"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["ES-419"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["de-DE", "es-ES"]), "es")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["de-DE"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "zh-Hans", preferredLanguages: ["fr-FR"]), "zh-Hans")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["zh-CN"]), "en")
        for tag in ["zh", "zh-CN", "zh-SG", "zh-Hans", "ZH-HANS-CN", "zh-Hans-HK"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "zh-Hans", tag)
        }
        for tag in ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "zh-Hant-CN"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "en", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["fr-CA"]), "fr")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["de-DE", "zh-CN"]), "zh-Hans")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: []), "en")
    }

    func testNativeStringsAndSystemPromptsShipInEveryAddedLocale() throws {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "es"), "Nueva pestaña")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "es"), "Unknown test string")
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "zh-Hans"), "新建标签页")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "zh-Hans"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "zh-Hans"), 3), "空间 3")
        #if !SWIFT_PACKAGE
        for locale in ["es", "zh-Hans"] {
            for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
                let url = try XCTUnwrap(Bundle.main.url(
                    forResource: resource, withExtension: "strings", subdirectory: nil, localization: locale
                ))
                XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "\(locale).lproj", resource)
            }
        }
        #endif
    }

    func testLanguageOverridesAlsoSelectTheLanguageOfSystemPanels() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        for locale in ["es", "zh-Hans"] {
            Localization.persistOverride(locale)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, locale)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], [locale])

            Localization.persistOverride("")
            // A normal lookup falls back to macOS's global language list once the override is removed.
            XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
        }
    }

    func testPortugueseSystemLanguagesUseTheBrazilianCatalog() {
        for tag in ["pt", "pt-BR", "PT-br", "pt-PT", "pt-AO"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "pt-BR", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "pt-BR", preferredLanguages: ["es-ES"]), "pt-BR")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["pt-BR"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: ["de-DE", "pt-BR"]), "pt-BR")
    }

    func testPortugueseChoicePersistsForNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("pt-BR")
        XCTAssertEqual(defaults.string(forKey: "lilo.locale"), "pt-BR")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["pt-BR"])
    }

    func testGeneratedPortugueseMenusAndDialogsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "pt-BR"), "Nova aba")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "pt-BR"), "Ajustes…")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "pt-BR"), 3), "Espaço 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "pt-BR"), "Example Extension"), "Instalar Example Extension?")
    }

    func testPortugueseSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("pt-BR.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "Este site solicita acesso à sua câmera.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "Abrir Espaço")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "Abrir um espaço no ${applicationName}")
        #endif
    }
}
