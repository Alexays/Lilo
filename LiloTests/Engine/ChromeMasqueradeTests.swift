import XCTest
@testable import Lilo

final class ChromeMasqueradeTests: XCTestCase {
    func testCurrentStoreHostMatches() {
        XCTAssertTrue(ChromeMasquerade.isStoreURL(URL(string: "https://chromewebstore.google.com/detail/foo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")!))
        XCTAssertTrue(ChromeMasquerade.isStoreHost("chromewebstore.google.com"))
    }

    func testLegacyStorePathMatchesByURLButNotBareHost() {
        XCTAssertTrue(ChromeMasquerade.isStoreURL(URL(string: "https://chrome.google.com/webstore/detail/foo/bar")!))
        // Bare chrome.google.com (non-webstore) must NOT masquerade.
        XCTAssertFalse(ChromeMasquerade.isStoreURL(URL(string: "https://chrome.google.com/sync")!))
        XCTAssertFalse(ChromeMasquerade.isStoreHost("chrome.google.com"))
    }

    func testNonStoreDoesNotMatch() {
        XCTAssertFalse(ChromeMasquerade.isStoreURL(URL(string: "https://example.com/")!))
        XCTAssertFalse(ChromeMasquerade.isStoreHost("example.com"))
    }

    func testUserAgentIsChrome() {
        XCTAssertTrue(ChromeMasquerade.chromeUserAgent.contains("Chrome/"))
        XCTAssertFalse(ChromeMasquerade.chromeUserAgent.contains("Lilo"))
    }
}
