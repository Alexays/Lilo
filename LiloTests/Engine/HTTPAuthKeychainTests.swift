import WebKit
import XCTest
@testable import Lilo

/// A remembered HTTP password belongs to one profile and goes with its cookies.
@MainActor
final class HTTPAuthKeychainTests: XCTestCase {
    private let space = URLProtectionSpace(
        host: "intranet.example", port: 443, protocol: "https", realm: "Staff", authenticationMethod: NSURLAuthenticationMethodHTTPBasic
    )
    private let profileA = UUID()
    private let profileB = UUID()

    override func tearDown() async throws {
        for profile in [profileA, profileB] {
            HTTPAuthKeychain.deleteAll(profileId: profile, modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: profile)
        }
    }

    func testACredentialStaysInItsProfileAndGoesWithItsCookies() async {
        HTTPAuthKeychain.store(URLCredential(user: "ada", password: "secret", persistence: .forSession), for: space, profileId: profileA)
        XCTAssertEqual(HTTPAuthKeychain.storedCredential(for: space, profileId: profileA)?.user, "ada")
        XCTAssertNil(HTTPAuthKeychain.storedCredential(for: space, profileId: profileB), "another profile is signed in too")

        let store = WKEngineFactory().createDataStore(persistent: true, identifier: profileA.uuidString)
        await store.removeCookies(modifiedSince: Date().addingTimeInterval(3600))
        XCTAssertNotNil(HTTPAuthKeychain.storedCredential(for: space, profileId: profileA), "a clear keeps what predates its range")

        await store.removeCookies(modifiedSince: .distantPast)
        XCTAssertNil(HTTPAuthKeychain.storedCredential(for: space, profileId: profileA), "clearing cookies leaves the sign-in")
    }
}
