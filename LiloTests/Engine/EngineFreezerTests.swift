import WebKit
import XCTest
@testable import Lilo

@MainActor
final class EngineFreezerTests: XCTestCase {
    func testCooperativeScriptDefinesFreezeAndResume() {
        let src = CooperativeFreezer.userScriptSource
        XCTAssertTrue(src.contains("__liloFreeze"))
        XCTAssertTrue(src.contains("__liloResume"))
        XCTAssertFalse(src.isEmpty)
    }

    func testFreezeResumeTogglesIsFrozenFlagIdempotently() {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        XCTAssertFalse(tab.isFrozen)
        tab.freeze()
        XCTAssertTrue(tab.isFrozen)
        tab.freeze()                 // idempotent
        XCTAssertTrue(tab.isFrozen)
        tab.resume()
        XCTAssertFalse(tab.isFrozen)
        tab.resume()                 // idempotent
        XCTAssertFalse(tab.isFrozen)
    }

    func testFreezeSuspendsPageTimersUntilResume() async throws {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        tab.wkWebView.loadHTMLString("<html><body><script>window.ticks = 0; setInterval(function () { window.ticks++; }, 10);</script></body></html>", baseURL: nil as URL?)
        let ticking = await pollUntil {
            ((try? await tab.wkWebView.evaluateJavaScript("window.ticks")) as? NSNumber)?.intValue ?? 0 > 0
        }
        XCTAssertTrue(ticking, "the page timer never started")
        let beforeValue = try await tab.wkWebView.evaluateJavaScript("window.ticks")
        let before = try XCTUnwrap(beforeValue as? NSNumber).intValue

        tab.freeze()
        // WebKit reports the page suspended about 3 s later on an idle machine, several times that under load.
        let suspended = await pollUntil(timeout: 45) { WebViewPrivateAccessors(tab.wkWebView).bool("_isSuspended") == true }
        XCTAssertTrue(suspended, "freeze must suspend the page, not only hint it")
        try await Task.sleep(nanoseconds: 300_000_000)

        tab.resume()
        let afterResumeValue = try await tab.wkWebView.evaluateJavaScript("window.ticks")
        let afterResume = try XCTUnwrap(afterResumeValue as? NSNumber).intValue
        XCTAssertLessThan(afterResume - before, 10, "timers kept firing while the page was frozen")
        XCTAssertEqual(WebViewPrivateAccessors(tab.wkWebView).bool("_isSuspended"), false)
        let resumed = await pollUntil {
            ((try? await tab.wkWebView.evaluateJavaScript("window.ticks")) as? NSNumber)?.intValue ?? 0 > afterResume
        }
        XCTAssertTrue(resumed, "timers must fire again after resume")
    }

    // WebKit raises NSInternalInconsistencyException from these on a suspended page, which would
    // take the test process down.
    func testCallsOnAFrozenTabSkipOrWakeInsteadOfRaising() async throws {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        tab.wkWebView.loadHTMLString("<html><body>frozen</body></html>", baseURL: nil as URL?)
        let loaded = await pollUntil { (try? await tab.wkWebView.evaluateJavaScript("document.body.textContent")) as? String == "frozen" }
        XCTAssertTrue(loaded)

        tab.freeze()
        XCTAssertTrue(CompositeFreezer.suspendedWebViews.contains(tab.wkWebView))
        XCTAssertTrue(tab.tryClose())
        tab.stopLoading()
        let preview = await tab.takePreviewSnapshot()
        XCTAssertNil(preview)
        XCTAssertTrue(tab.isFrozen, "skipped calls must leave the tab frozen")

        tab.reload()
        XCTAssertFalse(tab.isFrozen, "a navigation wakes the page")
        XCTAssertFalse(CompositeFreezer.suspendedWebViews.contains(tab.wkWebView))

        tab.freeze()
        tab.teardown()
    }

    func testFrozenTabWhoseProcessDiesIsLostAndDropsCalls() async throws {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        tab.wkWebView.loadHTMLString("<html><body>lost</body></html>", baseURL: nil as URL?)
        let loaded = await pollUntil { (try? await tab.wkWebView.evaluateJavaScript("document.body.textContent")) as? String == "lost" }
        XCTAssertTrue(loaded)
        let pid = try XCTUnwrap(WebViewPrivateAccessors(tab.wkWebView).pid("_webProcessIdentifier"))

        tab.freeze()
        kill(pid_t(pid), SIGKILL)
        let lost = await pollUntil { tab.isPageLost }
        XCTAssertTrue(lost, "the termination of a frozen page's process must mark it lost")

        XCTAssertFalse(tab.wake())
        tab.reload()
        tab.loadURL(URL(string: "about:blank")!)
        XCTAssertTrue(tab.isFrozen, "WebKit can no longer resume the page")
        tab.teardown()
    }
}
