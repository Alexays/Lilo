import Foundation
import WebKit
import XCTest
@testable import Lilo

final class NavigationFailureTests: XCTestCase {
    func testIgnoresFrameLoadInterruptedDownloadFailure() {
        let error = NSError(domain: "WebKitErrorDomain", code: 102)

        XCTAssertTrue(WKWebViewTab.shouldIgnoreNavigationFailure(error))
    }

    func testDoesNotIgnoreOrdinaryNetworkFailure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)

        XCTAssertFalse(WKWebViewTab.shouldIgnoreNavigationFailure(error))
    }

    func testIgnoresCancelledNavigationFailure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        XCTAssertTrue(WKWebViewTab.shouldIgnoreNavigationFailure(error))
    }

    func testIgnoresWKErrorFrameLoadInterruptedFailure() {
        let error = NSError(domain: WKError.errorDomain, code: 102)

        XCTAssertTrue(WKWebViewTab.shouldIgnoreNavigationFailure(error))
    }

    func testCommandClickMainFrameLinkOpensBackgroundTab() {
        XCTAssertTrue(
            WKWebViewTab.shouldOpenLinkInBackgroundTab(
                url: URL(string: "https://example.com/page"),
                isMainFrame: true,
                navigationType: .linkActivated,
                modifierFlags: [.command]
            )
        )
    }

    func testPlainMainFrameLinkDoesNotOpenBackgroundTab() {
        XCTAssertFalse(
            WKWebViewTab.shouldOpenLinkInBackgroundTab(
                url: URL(string: "https://example.com/page"),
                isMainFrame: true,
                navigationType: .linkActivated,
                modifierFlags: []
            )
        )
    }

    func testCommandClickSubframeLinkDoesNotOpenBackgroundTab() {
        XCTAssertFalse(
            WKWebViewTab.shouldOpenLinkInBackgroundTab(
                url: URL(string: "https://example.com/frame"),
                isMainFrame: false,
                navigationType: .linkActivated,
                modifierFlags: [.command]
            )
        )
    }

    func testAllowsMainFrameBasicAuthChallengeResponseEvenWithoutMimeType() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com/health")!,
            statusCode: 401,
            httpVersion: "HTTP/2",
            headerFields: ["WWW-Authenticate": #"Basic realm="Authorization Required""#]
        )!

        XCTAssertEqual(
            WKWebViewTab.policyForNavigationResponse(
                response,
                isMainFrame: true,
                canShowMIMEType: false
            ),
            .allow
        )
    }

    func testDownloadsMainFrameResponseWhenWebKitCannotShowMimeType() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/file")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/octet-stream"]
        )!

        XCTAssertEqual(
            WKWebViewTab.policyForNavigationResponse(
                response,
                isMainFrame: true,
                canShowMIMEType: false
            ),
            .download
        )
    }

    /// WebKit can follow a committed navigation with a second main-frame response carrying no URL and
    /// no MIME type (seen on youtube.com). The MIME rule must not read it as "cannot be shown" and turn
    /// it into a download of the page being viewed.
    func testAllowsMainFrameResponseThatCarriesNoMimeType() {
        let response = HTTPURLResponse(
            url: URL(string: "https://www.youtube.com/")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [:]
        )!
        XCTAssertNil(response.mimeType)

        XCTAssertEqual(
            WKWebViewTab.policyForNavigationResponse(
                response,
                isMainFrame: true,
                canShowMIMEType: false
            ),
            .allow
        )
    }

    func testStillDownloadsSubframeResponseWithoutMimeType() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/frame")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [:]
        )!

        XCTAssertEqual(
            WKWebViewTab.policyForNavigationResponse(
                response,
                isMainFrame: false,
                canShowMIMEType: false
            ),
            .download
        )
    }

    func testDownloadRequestAttachesRefererForHTTPPage() {
        let url = URL(string: "https://cdn.example.com/file.zip")!
        let pageURL = URL(string: "https://example.com/article")!

        let request = WKWebViewTab.downloadRequest(for: url, pageURL: pageURL)

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), pageURL.absoluteString)
        XCTAssertEqual(request.mainDocumentURL, pageURL)
    }

    func testDownloadRequestAttachesRefererForHTTPSPage() {
        let url = URL(string: "http://cdn.example.com/file.zip")!
        let pageURL = URL(string: "http://example.com/article")!

        let request = WKWebViewTab.downloadRequest(for: url, pageURL: pageURL)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), pageURL.absoluteString)
    }

    func testDownloadRequestOmitsRefererWhenPageURLIsNil() {
        let url = URL(string: "https://cdn.example.com/file.zip")!

        let request = WKWebViewTab.downloadRequest(for: url, pageURL: nil)

        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.mainDocumentURL)
    }

    func testDownloadRequestOmitsRefererForNonHTTPPage() {
        let url = URL(string: "https://cdn.example.com/file.zip")!
        let pageURL = URL(string: "file:///Users/me/local.html")!

        let request = WKWebViewTab.downloadRequest(for: url, pageURL: pageURL)

        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.mainDocumentURL)
    }

    func testRetriesSilentlyWhenConnectionRefusedWithNetworkUp() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)

        XCTAssertEqual(
            WKWebViewTab.recoveryForProvisionalFailure(error, alreadyRetried: false, isNetworkPathSatisfied: true),
            .retrySilently
        )
    }

    func testRetriesSilentlyWhenConnectionLostWithNetworkUp() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)

        XCTAssertEqual(
            WKWebViewTab.recoveryForProvisionalFailure(error, alreadyRetried: false, isNetworkPathSatisfied: true),
            .retrySilently
        )
    }

    func testSurfacesAndWaitsForConnectivityWhenNetworkDown() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        XCTAssertEqual(
            WKWebViewTab.recoveryForProvisionalFailure(error, alreadyRetried: false, isNetworkPathSatisfied: false),
            .surfaceAndRetryWhenOnline
        )
    }

    func testSurfacesTransientFailureAfterOneAutomaticRetry() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)

        XCTAssertEqual(
            WKWebViewTab.recoveryForProvisionalFailure(error, alreadyRetried: true, isNetworkPathSatisfied: true),
            .surface
        )
    }

    func testSurfacesUnknownHostFailureWithoutRetry() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)

        XCTAssertEqual(
            WKWebViewTab.recoveryForProvisionalFailure(error, alreadyRetried: false, isNetworkPathSatisfied: true),
            .surface
        )
    }

    func testSurfacesNonNetworkFailureWithoutRetry() {
        let error = NSError(domain: "WebKitErrorDomain", code: 999)

        XCTAssertEqual(
            WKWebViewTab.recoveryForProvisionalFailure(error, alreadyRetried: false, isNetworkPathSatisfied: true),
            .surface
        )
    }

    func testHTTPAuthCredentialStorageAccountSeparatesRealmsAndMethods() {
        let basicSpace = URLProtectionSpace(
            host: "api.example.com",
            port: 443,
            protocol: "https",
            realm: "Authorization Required",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let digestSpace = URLProtectionSpace(
            host: "api.example.com",
            port: 443,
            protocol: "https",
            realm: "Authorization Required",
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest
        )
        let otherRealmSpace = URLProtectionSpace(
            host: "api.example.com",
            port: 443,
            protocol: "https",
            realm: "Other",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )

        XCTAssertNotEqual(
            HTTPAuthKeychain.storageAccount(for: basicSpace),
            HTTPAuthKeychain.storageAccount(for: digestSpace)
        )
        XCTAssertNotEqual(
            HTTPAuthKeychain.storageAccount(for: basicSpace),
            HTTPAuthKeychain.storageAccount(for: otherRealmSpace)
        )
    }
}
