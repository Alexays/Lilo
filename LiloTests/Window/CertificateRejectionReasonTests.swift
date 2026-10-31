import Security
import XCTest
@testable import Lilo

// Self-signed, CN and SAN example.com.
private let selfSigned = "MIIDBDCCAeygAwIBAgIUWX8yWAGJrNkshASupYYvf0o97KMwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLZXhhbXBsZS5jb20wHhcNMjYxMDI3MTQxNjM3WhcNMjcxMDI3MTQxNjM3WjAWMRQwEgYDVQQDDAtleGFtcGxlLmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANYfBQDM6hR1b1hPNXizmqdR0L8T+e2hEL7v+pLeZhgwdUU0i/m5R3ZGrP4RBSbWxcieG//3klzRBGhF5G8k1dHSLzVgu93IgEZzG0jTSl8GCRr+q9VvIp7VQkfx+9bWwGziWOxGM2S0wj6ThNCQQaorwMtH80GYzTNrCLVdSyOG4+FmJdpxun+oqChu662X44/jRkvqFgtAXd6stX0+GeLxPBQ2/PjCajamnh1uFW6rm9dGwaRWXojXPdEaS87eFz0aANrTKzwrgeHUPqVwnOqg/uMbFNazN95+2EuTuIGoHaVktbpW/oZ7yP9lHCrytebAV12/m6Jj75gVy/j3SD8CAwEAAaNKMEgwHQYDVR0OBBYEFBuFqUJtRBdcYB3uSDkyMMojWtKlMA8GA1UdEwEB/wQFMAMBAf8wFgYDVR0RBA8wDYILZXhhbXBsZS5jb20wDQYJKoZIhvcNAQELBQADggEBAAdRuBVXBBwMLaVNK4PZuw8V4dQiRG8FeSd+eL9IVQW+dValHOEjllAkzuNyYNSRx45OeKWC7ZWS9/5ZkemtZOaJGbb9HzWbDNt53x3hqXMfrr0jYIKrXYn+M0c9S0WOtsGE4oJ0vbrLvDQnifXT1+RUrUyAcC0Bn4l8e8ug3L/27adK2VI32QKWTmTcPjwzL3dCyXJNPLDySsL4VWoGlhVdxzXH/7avf/J+7AlrjCHacCuwJx5/qpVOtID/JxUD+7FmlsDrD6Sfp1ZAtHpSALqRAcrdNdPy1LBzU1Bub5hCpVnO2YTB1ZcfcpVTgOGPCa6o0gtEuwIAFpqqaw7kbbk="

private func selfSignedTrust() throws -> SecTrust {
    let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, try XCTUnwrap(Data(base64Encoded: selfSigned)) as CFData))
    var trust: SecTrust?
    XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "example.com" as CFString), &trust), errSecSuccess)
    return try XCTUnwrap(trust)
}

final class CertificateRejectionReasonTests: XCTestCase {
    func testUntrustedCertificateNamesTheRejectedCertificate() throws {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let reason = try XCTUnwrap(MainWindowController.certificateRejectionReason(error, trust: try selfSignedTrust()))
        XCTAssertTrue(reason.contains("example.com"), reason)
    }

    func testOtherErrorsHaveNoCertificateReason() throws {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertNil(MainWindowController.certificateRejectionReason(error, trust: try selfSignedTrust()))
    }
}

/// A certificate exception holds for its profile or private Space, in every window, for any request to its host and port.
@MainActor
final class CertificateExceptionTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func engine(showing url: String, in space: Space, of window: MainWindowController) throws -> WKWebViewTab {
        window.switchToSpace(space.id)
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: url)))
        window.activateTabStateFirst(id: tab.id)
        return try XCTUnwrap(window.tabManager.activeEngineTab)
    }

    func testAnExceptionHoldsInEveryWindowOfItsProfileOnly() throws {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "A").id
        let work = try context.spaceManager.createSpace(name: "Work", profileId: profileId)
        let home = try context.spaceManager.createSpace(name: "Home", profileId: profileId)
        let otherProfile = try context.spaceManager.createSpace(name: "Other", profileId: try context.profileManager.createProfile(name: "B").id)
        let secret = try context.spaceManager.createSpace(name: "Private", profileId: profileId, isPrivate: true)
        let trust = try selfSignedTrust()
        let first = makeTestWindow(context, showing: work.id), second = makeTestWindow(context, showing: home.id)

        let accepting = try engine(showing: "https://example.com:8443/", in: work, of: first)
        first.allowInsecureTrust(forHost: "example.com")
        XCTAssertTrue(first.tab(accepting, shouldAllowInsecureServerTrust: trust, forHost: "example.com", port: 8443))
        XCTAssertFalse(first.tab(accepting, shouldAllowInsecureServerTrust: trust, forHost: "example.com", port: 443))

        let api = try engine(showing: "https://app.example.org/", in: home, of: second)
        XCTAssertTrue(
            second.tab(api, shouldAllowInsecureServerTrust: trust, forHost: "example.com", port: 8443),
            "another window and Space of the profile, from a page of another site"
        )
        for space in [otherProfile, secret] {
            let tab = try engine(showing: "https://example.com:8443/", in: space, of: second)
            XCTAssertFalse(second.tab(tab, shouldAllowInsecureServerTrust: trust, forHost: "example.com", port: 8443), space.name)
        }
    }

    func testAPrivateSpaceKeepsItsOwnException() throws {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "A").id
        let work = try context.spaceManager.createSpace(name: "Work", profileId: profileId)
        let secret = try context.spaceManager.createSpace(name: "Private", profileId: profileId, isPrivate: true)
        let trust = try selfSignedTrust()
        let window = makeTestWindow(context, showing: secret.id)

        let accepting = try engine(showing: "https://example.com/", in: secret, of: window)
        window.allowInsecureTrust(forHost: "example.com")
        XCTAssertTrue(window.tab(accepting, shouldAllowInsecureServerTrust: trust, forHost: "example.com", port: 443))

        let regular = try engine(showing: "https://example.com/", in: work, of: window)
        XCTAssertFalse(window.tab(regular, shouldAllowInsecureServerTrust: trust, forHost: "example.com", port: 443))
    }

    /// The HSTS preload list covers all of `.app`: its certificate errors offer no exception.
    func testACertificateErrorOnAnHSTSHostOffersNoException() throws {
        try XCTSkipIf(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFNetworkIsKnownHSTSHostWithSession") == nil, "no CFNetwork HSTS lookup")
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "Work", profileId: try context.profileManager.createProfile(name: "A").id)
        let window = makeTestWindow(context, showing: space.id)
        let tab = try engine(showing: "https://example.com/", in: space, of: window)
        let untrusted = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)

        window.tab(tab, didNavigate: .failed(URL(string: "https://example.com/"), untrusted))
        XCTAssertEqual(window.tabManager.activeTab?.navigationErrorUsesHSTS, false)
        window.tab(tab, didNavigate: .failed(URL(string: "https://shop.example.app/"), untrusted))
        XCTAssertEqual(window.tabManager.activeTab?.navigationErrorUsesHSTS, true)
        window.tab(tab, didNavigate: .failed(URL(string: "https://shop.example.app/"), NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertEqual(window.tabManager.activeTab?.navigationErrorUsesHSTS, false)

        window.tab(tab, didNavigate: .failed(URL(string: "https://shop.example.app/"), untrusted))
        window.allowInsecureTrust(forHost: "shop.example.app")
        XCTAssertFalse(window.tab(tab, shouldAllowInsecureServerTrust: try selfSignedTrust(), forHost: "shop.example.app", port: 443))
    }
}
