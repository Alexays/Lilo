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
                modifierFlags: [.command],
                buttonNumber: 1
            )
        )
    }

    func testPlainMainFrameLinkDoesNotOpenBackgroundTab() {
        XCTAssertFalse(
            WKWebViewTab.shouldOpenLinkInBackgroundTab(
                url: URL(string: "https://example.com/page"),
                isMainFrame: true,
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 1
            )
        )
    }

    func testMiddleClickMainFrameLinkOpensBackgroundTab() {
        XCTAssertTrue(
            WKWebViewTab.shouldOpenLinkInBackgroundTab(
                url: URL(string: "https://example.com/page"),
                isMainFrame: true,
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: WKWebViewTab.middleButtonNumber
            )
        )
    }

    func testCommandClickSubframeLinkDoesNotOpenBackgroundTab() {
        XCTAssertFalse(
            WKWebViewTab.shouldOpenLinkInBackgroundTab(
                url: URL(string: "https://example.com/frame"),
                isMainFrame: false,
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 1
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

    func testDownloadsAttachmentEvenWhenWebKitCanShowMimeType() {
        let attachment = HTTPURLResponse(
            url: URL(string: "https://example.com/export?format=pdf")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/pdf", "Content-Disposition": #"Attachment; filename="doc.pdf""#]
        )!
        let inline = HTTPURLResponse(
            url: URL(string: "https://example.com/doc.pdf")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/pdf", "Content-Disposition": #"inline; filename="attachment.pdf""#]
        )!

        let expiredLink = HTTPURLResponse(
            url: URL(string: "https://example.com/export?format=pdf")!,
            statusCode: 404,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "text/html", "Content-Disposition": #"attachment; filename="doc.pdf""#]
        )!

        for isMainFrame in [true, false] {
            XCTAssertEqual(
                WKWebViewTab.policyForNavigationResponse(attachment, isMainFrame: isMainFrame, canShowMIMEType: true),
                .download
            )
            XCTAssertEqual(
                WKWebViewTab.policyForNavigationResponse(expiredLink, isMainFrame: isMainFrame, canShowMIMEType: true),
                .allow
            )
            XCTAssertEqual(
                WKWebViewTab.policyForNavigationResponse(inline, isMainFrame: isMainFrame, canShowMIMEType: true),
                .allow
            )
        }
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

    private func recovery(
        _ error: NSError, sendsBody: Bool = false, alreadyRetried: Bool = false, online: Bool = true
    ) -> WKWebViewTab.NavigationFailureRecovery {
        WKWebViewTab.recoveryForNavigationFailure(error, sendsBody: sendsBody, alreadyRetried: alreadyRetried, isNetworkPathSatisfied: online)
    }

    func testRetriesSilentlyWhenConnectionRefusedLostOrTimedOutWithNetworkUp() {
        for code in [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut] {
            XCTAssertEqual(recovery(NSError(domain: NSURLErrorDomain, code: code)), .retrySilently, "code \(code)")
        }
    }

    func testSurfacesAndWaitsForANetworkChangeWhenNetworkDown() {
        XCTAssertEqual(recovery(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), online: false), .surfaceAndRetryOnNetworkChange)
    }

    func testSurfacesAndWaitsForANetworkChangeAfterOneAutomaticRetry() {
        XCTAssertEqual(recovery(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), alreadyRetried: true), .surfaceAndRetryOnNetworkChange)
    }

    func testRetriesADNSLookupThatGotNoAnswer() {
        let timedOut = NSError(domain: "kNWErrorDomainDNS", code: -65568)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: [NSUnderlyingErrorKey: timedOut])

        XCTAssertEqual(recovery(error), .retrySilently)
    }

    func testSurfacesAHostTheDNSSaysDoesNotExistWithoutRetry() {
        let noSuchRecord = NSError(domain: "kNWErrorDomainDNS", code: -65554)
        let fromNetwork = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: [NSUnderlyingErrorKey: noSuchRecord])
        let fromCFNetwork = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                    userInfo: ["_kCFStreamErrorDomainKey": 12, "_kCFStreamErrorCodeKey": 8])

        XCTAssertEqual(recovery(fromNetwork), .surface)
        XCTAssertEqual(recovery(fromCFNetwork, online: false), .surface)
    }

    func testNeverReplaysALoadWithABody() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)

        XCTAssertEqual(recovery(error, sendsBody: true), .surface)
        XCTAssertEqual(recovery(error, sendsBody: true, online: false), .surface)
    }

    func testSurfacesNonNetworkFailureWithoutRetry() {
        XCTAssertEqual(recovery(NSError(domain: "WebKitErrorDomain", code: 999)), .surface)
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
