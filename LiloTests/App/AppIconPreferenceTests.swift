import XCTest
@testable import Lilo

/// Seasonal app icons: when each season runs, and that every variant ships its seasonal images.
final class AppIconPreferenceTests: XCTestCase {
    private func date(_ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
    }

    func testSeasonsRunOnTheirDays() throws {
        XCTAssertNil(AppIconPreference.season(on: try date(10, 23)))
        XCTAssertEqual(AppIconPreference.season(on: try date(10, 24)), "halloween")
        XCTAssertEqual(AppIconPreference.season(on: try date(10, 31)), "halloween")
        XCTAssertNil(AppIconPreference.season(on: try date(11, 1)))
        XCTAssertNil(AppIconPreference.season(on: try date(12, 14)))
        XCTAssertEqual(AppIconPreference.season(on: try date(12, 15)), "christmas")
        XCTAssertEqual(AppIconPreference.season(on: try date(12, 26)), "christmas")
        XCTAssertNil(AppIconPreference.season(on: try date(12, 27)))
        XCTAssertEqual(AppIconPreference.season(on: try date(12, 31)), "newyear")
        XCTAssertEqual(AppIconPreference.season(on: try date(1, 1)), "newyear")
        XCTAssertNil(AppIconPreference.season(on: try date(1, 2)))
        XCTAssertNil(AppIconPreference.season(on: try date(2, 13)))
        XCTAssertEqual(AppIconPreference.season(on: try date(2, 14)), "valentine")
        XCTAssertNil(AppIconPreference.season(on: try date(2, 15)))
        // The 2026 lunar year starts on February 17.
        XCTAssertNil(AppIconPreference.season(on: try date(2, 16)))
        XCTAssertEqual(AppIconPreference.season(on: try date(2, 17)), "lunar")
        XCTAssertEqual(AppIconPreference.season(on: try date(2, 23)), "lunar")
        XCTAssertNil(AppIconPreference.season(on: try date(2, 24)))
        // Easter 2026 is April 5.
        XCTAssertNil(AppIconPreference.season(on: try date(4, 2)))
        XCTAssertEqual(AppIconPreference.season(on: try date(4, 3)), "easter")
        XCTAssertEqual(AppIconPreference.season(on: try date(4, 6)), "easter")
        XCTAssertNil(AppIconPreference.season(on: try date(4, 7)))
        XCTAssertEqual(AppIconPreference.season(on: try date(4, 22)), "birthday")
        XCTAssertNil(AppIconPreference.season(on: try date(4, 23)))
        XCTAssertNil(AppIconPreference.season(on: try date(6, 19)))
        XCTAssertEqual(AppIconPreference.season(on: try date(6, 20)), "summer")
        XCTAssertEqual(AppIconPreference.season(on: try date(6, 22)), "summer")
        XCTAssertNil(AppIconPreference.season(on: try date(6, 23)))
    }

    func testEveryVariantHasItsSeasonalImages() {
        for season in ["halloween", "christmas", "newyear", "valentine", "lunar", "easter", "summer", "birthday"] {
            for variant in AppIconPreference.variants {
                XCTAssertNotNil(Bundle.main.url(forResource: variant, withExtension: "png", subdirectory: "AppIcons/\(season)"), "\(season)/\(variant)")
            }
        }
    }
}
