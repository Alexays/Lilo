import XCTest
@testable import Lilo

final class KoreanLocalizationTests: XCTestCase {
    func testKoreanSystemLanguagesAndOverrides() {
        for tag in ["ko", "ko-KR", "KO-kr"] {
            XCTAssertEqual(Localization.resolveLocale(override: nil, preferredLanguages: [tag]), "ko", tag)
        }
        XCTAssertEqual(Localization.resolveLocale(override: "ko", preferredLanguages: ["fr-FR"]), "ko")
        XCTAssertEqual(Localization.resolveLocale(override: "en", preferredLanguages: ["KO-kr"]), "en")
        XCTAssertEqual(Localization.resolveLocale(override: "unknown", preferredLanguages: ["ar-SA", "KO-kr"]), "ko")
    }

    func testKoreanNativeStringsPreserveFormatArguments() {
        XCTAssertEqual(NativeStrings.translate("New Tab", locale: "ko"), "새 탭")
        XCTAssertEqual(NativeStrings.translate("Settings…", locale: "ko"), "설정…")
        XCTAssertEqual(NativeStrings.translate("Unknown test string", locale: "ko"), "Unknown test string")
        XCTAssertEqual(String(format: NativeStrings.translate("Space %d", locale: "ko"), 3), "스페이스 3")
        XCTAssertEqual(String(format: NativeStrings.translate("Install %@?", locale: "ko"), "Example Extension"),
                       "Example Extension 항목을 설치하겠습니까?")
    }

    func testKoreanSystemPromptsAndShortcutsAreBundled() throws {
        #if !SWIFT_PACKAGE
        for resource in ["InfoPlist", "Localizable", "AppShortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: resource, withExtension: "strings", subdirectory: nil, localization: "ko"
            ))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "ko.lproj", resource)
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("ko.lproj")))
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"),
                       "이 웹사이트에서 카메라에 접근하려고 합니다.")
        XCTAssertEqual(bundle.localizedString(forKey: "Open Space", value: nil, table: "Localizable"), "스페이스 열기")
        XCTAssertEqual(bundle.localizedString(forKey: "Open a space in ${applicationName}", value: nil, table: "AppShortcuts"),
                       "${applicationName}에서 스페이스 열기")
        #endif
    }

    func testKoreanOverrideSelectsNativeAndSystemUI() {
        let defaults = UserDefaults.lilo
        let domain = "\(UserDefaults.testDomainPrefix)\(getpid())"
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            defaults.set(previous?["lilo.locale"], forKey: "lilo.locale")
            defaults.set(previous?["AppleLanguages"], forKey: "AppleLanguages")
        }

        Localization.persistOverride("ko")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["lilo.locale"] as? String, "ko")
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["ko"])
        Localization.persistOverride("")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }
}
