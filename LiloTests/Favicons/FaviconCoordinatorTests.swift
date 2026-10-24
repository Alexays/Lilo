import XCTest
@testable import Lilo

@MainActor
final class FaviconCoordinatorTests: XCTestCase {
    private func makeCoordinator(service: FaviconService) -> FaviconCoordinator {
        FaviconCoordinator(service: service, applyFavicon: { _, _, _ in })
    }

    func testWarmSeedsCacheForTabsWithKnownFavicons() {
        let service = FaviconService()
        let coordinator = makeCoordinator(service: service)

        var tab = Tab(url: URL(string: "https://example.com/page"), title: "Example", spaceId: UUID())
        tab.faviconDataURL = "data:image/png;base64,AAAA"

        XCTAssertNil(service.cached(for: "example.com"))
        coordinator.warm(from: [tab])
        XCTAssertNotNil(service.cached(for: "example.com"))
    }

    func testWarmIgnoresTabsMissingURLorFavicon() {
        let service = FaviconService()
        let coordinator = makeCoordinator(service: service)

        var noFavicon = Tab(url: URL(string: "https://nofavicon.example"), title: "No Favicon", spaceId: UUID())
        noFavicon.faviconDataURL = nil
        let noURL = Tab(title: "No URL", spaceId: UUID())

        coordinator.warm(from: [noFavicon, noURL])
        XCTAssertNil(service.cached(for: "nofavicon.example"))
    }
}
