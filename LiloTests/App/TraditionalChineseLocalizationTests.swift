import XCTest
@testable import Lilo

final class TraditionalChineseLocalizationTests: XCTestCase {
    func testTraditionalChineseSystemLanguagesAndOverrides() {
        for tag in ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "ZH-HANT-TW", "zh-Hant-CN"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "zh-Hant", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "zh-Hant", preferredLanguages: ["fr-FR"]), "zh-Hant")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["zh-Hant-CN"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "zh-Hant-CN"]), "zh-Hant")
    }

    func testTraditionalChineseNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "zh-Hant"), "新增分頁")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "zh-Hant"), "設定…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "zh-Hant"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "zh-Hant"), 3), "空間 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "zh-Hant"), "Example Extension"),
                       "要安裝 Example Extension 嗎？")
    }

    func testTraditionalChineseSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "zh-Hant"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "zh-Hant.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("zh-Hant.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "此網站要求取用相機。")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "開啟空間")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "在 ${applicationName} 中開啟空間")
        #endif
    }

    func testTraditionalChineseOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("zh-Hant")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "zh-Hant")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["zh-Hant"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
