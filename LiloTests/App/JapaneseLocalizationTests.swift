import XCTest
@testable import Lilo

final class JapaneseLocalizationTests: XCTestCase {
    func testJapaneseSystemLanguagesAndOverrides() {
        for tag in ["ja", "ja-JP", "JA-jp"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "ja", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "ja", preferredLanguages: ["fr-FR"]), "ja")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["JA-jp"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "JA-jp"]), "ja")
    }

    func testJapaneseNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "ja"), "新規タブ")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "ja"), "設定…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "ja"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "ja"), 3), "スペース 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "ja"), "Example Extension"),
                       "Example Extension をインストールしますか？")
    }

    func testJapaneseSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "ja"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "ja.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("ja.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "この Web サイトがカメラへのアクセスを求めています。")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "スペースを開く")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "${applicationName}でスペースを開く")
        #endif
    }

    func testJapaneseOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("ja")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "ja")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["ja"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
