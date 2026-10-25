import AppKit
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

    func testASiteSwitchingIconsOnTheSameHostUpdatesTheTabAndItsHomeIcon() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let window = makeTestWindow(context, showing: space.id)
        defer { window.close() }

        let page = { (icon: String) in Data("<html><head><link rel=\"icon\" href=\"/\(icon).png\"></head><body></body></html>".utf8) }
        let png = { (color: NSColor) -> Data in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<16 { for y in 0..<16 { rep.setColor(color, atX: x, y: y) } }
            return rep.representation(using: .png, properties: [:])!
        }
        let (signedOut, signedIn) = (png(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)), png(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)))
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET /login ") { return ("200 OK", ["Content-Type: text/html"], page("signed-out")) }
            if request.hasPrefix("GET /inbox ") { return ("200 OK", ["Content-Type: text/html"], page("signed-in")) }
            if request.hasPrefix("GET /signed-out.png ") { return ("200 OK", ["Content-Type: image/png"], signedOut) }
            if request.hasPrefix("GET /signed-in.png ") { return ("200 OK", ["Content-Type: image/png"], signedIn) }
            return ("404 Not Found", [], Data())
        }
        let home = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/login"))
        let tab = Tab(url: home, title: "Sign in", isPinned: true, homeURL: home, homeTitle: "Sign in")
        try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: tab, activate: true))
        window.tabManager.load(home, inTab: tab.id)

        let firstIcon = await pollUntil(timeout: 10) { window.tabManager.tab(for: tab.id)?.faviconDataURL != nil }
        XCTAssertTrue(firstIcon)
        let before = window.tabManager.tab(for: tab.id)?.faviconDataURL

        window.tabManager.load(try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/inbox")), inTab: tab.id)
        let switched = await pollUntil(timeout: 10) { window.tabManager.tab(for: tab.id)?.faviconDataURL != before }
        XCTAssertTrue(switched, "the cached icon of the host gives way to the one the page now offers")
        let after = window.tabManager.tab(for: tab.id)
        XCTAssertEqual(after?.homeFaviconDataURL, after?.faviconDataURL, "the home icon follows its site")
    }
}
