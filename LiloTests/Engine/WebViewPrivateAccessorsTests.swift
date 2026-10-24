import XCTest
import WebKit
@testable import Lilo

@MainActor
final class WebViewPrivateAccessorsTests: XCTestCase {
    func testReadsPrivateSelectorsWithoutCrashing() {
        let webView = WKWebView(frame: .zero)
        let accessors = WebViewPrivateAccessors(webView)
        // A fresh web view has no committed content; the read must return nil, not trap.
        XCTAssertNil(accessors.urlString("_committedURL"))
        // A non-existent selector is filtered by the responds(to:) guard.
        XCTAssertNil(accessors.bool("_definitelyNotARealSelector"))
    }

    func testSetUIntInvokesPageMuteAndNoOpsForMissingSelector() {
        let webView = WKWebView(frame: .zero)
        let accessors = WebViewPrivateAccessors(webView)
        // Real private setter: must invoke without trapping (mute then unmute).
        accessors.setUInt("_setPageMuted:", 1)
        accessors.setUInt("_setPageMuted:", 0)
        // A non-existent selector is filtered by the responds(to:) guard, so this must not crash.
        accessors.setUInt("_definitelyNotARealSetter:", 1)
    }

    func testInvokeReturnsFalseForAbsentSelector() {
        let webView = WKWebView(frame: .zero)
        let accessors = WebViewPrivateAccessors(webView)
        XCTAssertFalse(accessors.invoke("_liloDefinitelyNotARealSelector:") { _ in XCTFail("completion must not run") })
    }
}
