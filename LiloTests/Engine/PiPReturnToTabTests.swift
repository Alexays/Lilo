import WebKit
import XCTest
@testable import Lilo

/// The PiP window's return button reaches the app only through the private
/// `_webViewFullscreenMayReturnToInline:` UI-delegate selector, so both the exact selector name and
/// its routing to `tabRequestsForeground` are load-bearing.
@MainActor
final class PiPReturnToTabTests: XCTestCase {

    func testReturnToInlineForegroundsTheOwningTab() {
        let tab = WKWebViewTab(id: UUID(), configuration: WKWebViewConfiguration())
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy

        tab.perform(NSSelectorFromString("_webViewFullscreenMayReturnToInline:"), with: tab.view)

        XCTAssertEqual(spy.foregroundRequests, 1)
    }
}
