import Security
import XCTest
@testable import Lilo

/// chrome.identity: a token cache per profile and extension, never removed for another one, and hidden web auth flows.
@MainActor
final class IdentityBridgeHandlerTests: XCTestCase {
    private let service = BuildIdentity.appIdentifier + ".identity"
    private let caller = "test-\(UUID().uuidString)"
    private let neighbor = "test-\(UUID().uuidString)"
    private let otherProfile = UUID()

    override func tearDown() {
        for profile in [gapTestRegistry.profileId, otherProfile] {
            for id in [caller, neighbor] {
                for scope in ["email", "profile"] {
                    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "\(profile.uuidString)\u{1f}\(id)\u{1f}\(scope)"] as CFDictionary)
                }
            }
        }
        super.tearDown()
    }

    private func cache(_ token: String, for extensionId: String, scope: String, expiresIn: TimeInterval,
                       profile: UUID? = nil) {
        let profile = profile ?? gapTestRegistry.profileId
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "\(profile.uuidString)\u{1f}\(extensionId)\u{1f}\(scope)", kSecValueData as String: Data(token.utf8),
            kSecAttrGeneric as String: Data(String(Date().addingTimeInterval(expiresIn).timeIntervalSince1970).utf8)
        ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
    }

    private func send(_ action: String, _ payload: [String: Any], as extensionId: String) async throws -> Any? {
        var payload = payload
        payload["extensionId"] = extensionId
        return await IdentityBridgeHandler().handle(try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload])))
    }

    func testAnUncachedTokenNeedsAnInteractiveSignInAndAClientId() async throws {
        let silent = try await send("identity.getAuthToken", ["scopes": ["email"]], as: caller)
        let interactive = try await send("identity.getAuthToken", ["scopes": ["email"], "interactive": true], as: caller)

        XCTAssertEqual((silent as? BridgeError)?.message, "The user is not signed in.")
        XCTAssertEqual((interactive as? BridgeError)?.message, "Invalid OAuth2 Client ID.", "no manifest oauth2 client: no sign-in")
    }

    func testACachedTokenIsReturnedUntilItExpires() async throws {
        cache("fresh", for: caller, scope: "email", expiresIn: 3600)
        cache("stale", for: caller, scope: "profile", expiresIn: 30)

        let fresh = try await send("identity.getAuthToken", ["scopes": ["email"]], as: caller) as? [String: Any]
        let stale = try await send("identity.getAuthToken", ["scopes": ["profile"]], as: caller)

        XCTAssertEqual(fresh?["token"] as? String, "fresh")
        XCTAssertEqual(fresh?["grantedScopes"] as? [String], ["email"])
        XCTAssertNotNil(stale as? BridgeError, "a token expiring within the minute is not handed out")
    }

    func testATokenCachedInAnotherProfileIsNotHandedOut() async throws {
        cache("elsewhere", for: caller, scope: "email", expiresIn: 3600, profile: otherProfile)

        let result = try await send("identity.getAuthToken", ["scopes": ["email"]], as: caller)

        XCTAssertEqual((result as? BridgeError)?.message, "The user is not signed in.")
    }

    func testRemovingTokensNeverReachesAnotherExtension() async throws {
        cache("mine", for: caller, scope: "email", expiresIn: 3600)
        cache("mine", for: neighbor, scope: "email", expiresIn: 3600)
        cache("other", for: caller, scope: "profile", expiresIn: 3600)

        _ = try await send("identity.removeCachedAuthToken", ["token": "mine"], as: caller)
        let removed = try await send("identity.getAuthToken", ["scopes": ["email"]], as: caller)
        let kept = try await send("identity.getAuthToken", ["scopes": ["profile"]], as: caller) as? [String: Any]
        _ = try await send("identity.clearAllCachedAuthTokens", [:], as: caller)
        let cleared = try await send("identity.getAuthToken", ["scopes": ["profile"]], as: caller)
        let neighbors = try await send("identity.getAuthToken", ["scopes": ["email"]], as: neighbor) as? [String: Any]

        XCTAssertNotNil(removed as? BridgeError)
        XCTAssertEqual(kept?["token"] as? String, "other", "only the token named goes")
        XCTAssertNotNil(cleared as? BridgeError)
        XCTAssertEqual(neighbors?["token"] as? String, "mine", "another extension's identical token stays")
    }

    func testANonInteractiveFlowResolvesWhenItReachesTheRedirectUnaided() async throws {
        let redirect = "https://\(caller.lowercased()).chromiumapp.org/cb#access_token=made-up"

        let result = try await send("identity.launchWebAuthFlow", ["url": redirect, "interactive": false], as: caller)

        XCTAssertEqual(result as? String, redirect)
    }

    func testANonInteractiveFlowFailsWhereTheUserWouldHaveToAct() async throws {
        let page = "data:text/html,sign-in"

        let loaded = try await send("identity.launchWebAuthFlow", ["url": page], as: caller)
        let timedOut = try await send("identity.launchWebAuthFlow", [
            "url": page, "abortOnLoadForNonInteractive": false, "timeoutMsForNonInteractive": 100
        ], as: caller)

        XCTAssertEqual((loaded as? BridgeError)?.message, "User interaction required.", "the page loaded without redirecting")
        XCTAssertEqual((timedOut as? BridgeError)?.message, "User interaction required.", "no redirect within the timeout")
    }
}
