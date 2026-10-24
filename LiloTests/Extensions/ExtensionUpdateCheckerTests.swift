import XCTest
@testable import Lilo

final class ExtensionUpdateCheckerTests: XCTestCase {
    func testUsesGoogleUpdateService() {
        XCTAssertTrue(ExtensionUpdateChecker.usesGoogleUpdateService(nil))
        XCTAssertTrue(ExtensionUpdateChecker.usesGoogleUpdateService(""))
        XCTAssertTrue(ExtensionUpdateChecker.usesGoogleUpdateService("https://clients2.google.com/service/update2/crx"))
        XCTAssertFalse(ExtensionUpdateChecker.usesGoogleUpdateService("https://self-hosted.example.com/updates.xml"))
    }

    func testUpdateCheckURLBatchesEveryExtension() throws {
        let url = try XCTUnwrap(ExtensionUpdateChecker.updateCheckURL(extensions: [
            (id: "abcdefghijklmnopabcdefghijklmnop", version: "1.2.3"),
            (id: "ponmlkjihgfedcbaponmlkjihgfedcba", version: "4.5")
        ])).absoluteString
        XCTAssertTrue(url.hasPrefix("https://clients2.google.com/service/update2/crx?response=updatecheck"))
        XCTAssertTrue(url.contains("prodversion=\(ExtensionUpdateChecker.prodVersion)&"))
        XCTAssertEqual(url.components(separatedBy: "&x=").count, 3)
        XCTAssertTrue(url.contains("abcdefghijklmnopabcdefghijklmnop"))
        XCTAssertTrue(url.contains("ponmlkjihgfedcbaponmlkjihgfedcba"))
        XCTAssertFalse(url.contains("response=redirect"))  // this is a check, not a download
        XCTAssertNil(ExtensionUpdateChecker.updateCheckURL(extensions: []))
    }

    func testProdVersionFollowsTheMasqueradeUserAgent() {
        XCTAssertTrue(ChromeMasquerade.chromeUserAgent.contains("Chrome/\(ExtensionUpdateChecker.prodVersion) "))
    }

    func testLatestVersionsParsesEveryApp() {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
          <app appid="abcdefghijklmnopabcdefghijklmnop" status="ok">
            <updatecheck status="ok" codebase="https://x/ext.crx" prodversionmin="120.0" version="3.4.5"/>
          </app>
          <app appid="ponmlkjihgfedcbaponmlkjihgfedcba" status="ok">
            <updatecheck status="noupdate"/>
          </app>
        </gupdate>
        """.utf8)
        XCTAssertEqual(ExtensionUpdateChecker.latestVersions(from: xml), ["abcdefghijklmnopabcdefghijklmnop": "3.4.5"])
    }

    func testLatestVersionsEmptyForGarbage() {
        XCTAssertEqual(ExtensionUpdateChecker.latestVersions(from: Data("not xml".utf8)), [:])
        XCTAssertEqual(ExtensionUpdateChecker.latestVersions(from: Data()), [:])
    }

    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(ExtensionUpdateChecker.isNewer("1.10", than: "1.9"))     // not string order
        XCTAssertTrue(ExtensionUpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertTrue(ExtensionUpdateChecker.isNewer("1.2.3.1", than: "1.2.3"))
        XCTAssertFalse(ExtensionUpdateChecker.isNewer("1.2.3", than: "1.2.3"))
        XCTAssertFalse(ExtensionUpdateChecker.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(ExtensionUpdateChecker.isNewer("1.2.0", than: "1.3"))
    }
}
