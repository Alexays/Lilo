import XCTest
@testable import Lilo

/// Stored site-permission grants are keyed `scheme://host` for default-port origins, so those must keep resolving to the
/// same key or they silently lose their grant.
final class PermissionOriginKeyTests: XCTestCase {

    private struct Case {
        let scheme: String
        let host: String
        let port: Int
        let expected: String
        let name: String
    }

    private static let cases: [Case] = [
        // Default ports must collapse to the portless key: this IS the back-compat contract with
        // grants stored as "scheme://host" for these origins.
        Case(scheme: "https", host: "site.example", port: 443, expected: "https://site.example", name: "https default port 443 stripped"),
        Case(scheme: "http", host: "site.example", port: 80, expected: "http://site.example", name: "http default port 80 stripped"),
        // WKSecurityOrigin.port reports 0 when no explicit port was given at all.
        Case(scheme: "https", host: "site.example", port: 0, expected: "https://site.example", name: "port 0 (none given) treated as no port"),
        Case(scheme: "http", host: "site.example", port: 0, expected: "http://site.example", name: "port 0 (none given), http scheme"),
        // Non-default ports must be preserved so they key separately from the bare origin.
        Case(scheme: "https", host: "site.example", port: 8443, expected: "https://site.example:8443", name: "https non-default port kept"),
        Case(scheme: "http", host: "site.example", port: 8080, expected: "http://site.example:8080", name: "http non-default port kept"),
        // Cross-scheme default-port mismatch: port 80 on https is NOT https's default, so it must
        // be kept (distinguishes an unusual https-on-80 origin from the ordinary https default).
        Case(scheme: "https", host: "site.example", port: 80, expected: "https://site.example:80", name: "http's default port kept when scheme is https"),
        Case(scheme: "http", host: "site.example", port: 443, expected: "http://site.example:443", name: "https's default port kept when scheme is http"),
    ]

    func testPermissionOriginKeyTable() {
        for testCase in Self.cases {
            let actual = PermissionOriginKey.build(scheme: testCase.scheme, host: testCase.host, port: testCase.port)
            XCTAssertEqual(actual, testCase.expected, testCase.name)
        }
    }

    /// The external-scheme prompt (`MainWindowController+Navigation.launchExternalURL`) derives
    /// the key from a page `URL`, whose `port` is `nil` (not 0) when no port is written in the
    /// URL. It feeds `pageURL?.port ?? 0` into the helper; this verifies that convention end to end.
    func testURLDerivedPortConvention() {
        let defaultPortURL = URL(string: "https://x.example/page")!
        XCTAssertNil(defaultPortURL.port, "URL.port must be nil when the URL spells no port")
        XCTAssertEqual(
            PermissionOriginKey.build(scheme: defaultPortURL.scheme!, host: defaultPortURL.host!, port: defaultPortURL.port ?? 0),
            "https://x.example",
            "nil URL.port coalesced to 0 must collapse to the historical portless key"
        )

        let explicitDefaultURL = URL(string: "http://x.example:80/page")!
        XCTAssertEqual(
            PermissionOriginKey.build(scheme: explicitDefaultURL.scheme!, host: explicitDefaultURL.host!, port: explicitDefaultURL.port ?? 0),
            "http://x.example",
            "an explicitly-written default port must still collapse"
        )

        let customPortURL = URL(string: "https://x.example:9443/page")!
        XCTAssertEqual(
            PermissionOriginKey.build(scheme: customPortURL.scheme!, host: customPortURL.host!, port: customPortURL.port ?? 0),
            "https://x.example:9443",
            "a non-default URL port must be appended"
        )
    }
}
