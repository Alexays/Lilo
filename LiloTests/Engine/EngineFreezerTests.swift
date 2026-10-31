import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class EngineFreezerTests: XCTestCase {
    func testCooperativeFreezeHidesThePageUntilResume() async throws {
        let configuration = WKWebViewConfiguration()
        PageWorld.install([CooperativeFreezer.pageModule], on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<script>window.changes = 0; document.addEventListener('visibilitychange', () => changes++)</script>",
                               baseURL: URL(string: "https://example.com/"))
        // The initial about:blank already reads complete: wait for this page.
        let loaded = await pollUntil(timeout: 5) {
            ((try? await webView.evaluateJavaScript("location.href === 'https://example.com/' && document.readyState === 'complete'")) as? Bool) == true
        }
        XCTAssertTrue(loaded)
        let state = "[document.visibilityState, document.hidden, changes].join()"
        // A web view outside a window is hidden to WebKit already: a resume returns the page to that.
        let native = try await webView.evaluateJavaScript("[document.visibilityState, document.hidden].join()") as? String

        _ = try? await webView.evaluateJavaScript(PageWorld.push("freeze"), contentWorld: PageWorld.bridgeWorld)
        let frozen = try await webView.evaluateJavaScript(state) as? String
        XCTAssertEqual(frozen, "hidden,true,1")
        _ = try? await webView.evaluateJavaScript(PageWorld.push("resume"), contentWorld: PageWorld.bridgeWorld)
        let resumed = try await webView.evaluateJavaScript(state) as? String
        XCTAssertEqual(resumed, "\(native ?? ""),2")
    }

    func testCooperativeFreezePlaysAgainOnResumeTheMediaItPaused() async throws {
        let configuration = WKWebViewConfiguration()
        PageWorld.install([CooperativeFreezer.pageModule], on: configuration.userContentController)
        let tab = WKWebViewTab(configuration: configuration)
        let webView = tab.wkWebView
        // A page plays video only in a window it counts as visible, even under other apps' windows (as on CI).
        tab.setWindowOcclusionDetection(false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.view
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            tab.teardown()
        }
        webView.loadHTMLString(PiPControllerTests.silentVideo + "<video id='idle' muted></video>", baseURL: URL(string: "https://video.example/"))
        let playing = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript("!v.paused")) as? Bool == true }
        XCTAssertTrue(playing)
        let paused = "[v.paused, idle.paused].join()"

        _ = try? await webView.evaluateJavaScript(PageWorld.push("freeze"), contentWorld: PageWorld.bridgeWorld)
        let frozen = try await webView.evaluateJavaScript(paused) as? String
        XCTAssertEqual(frozen, "true,true")
        _ = try? await webView.evaluateJavaScript(PageWorld.push("resume"), contentWorld: PageWorld.bridgeWorld)
        let resumed = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript(paused)) as? String == "false,true" }
        XCTAssertTrue(resumed, "a silent loop plays again, and a video that was not playing stays paused")
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
        // What WebKit's scripting.executeScript sends once its frame-tree round trip returns.
        let selector = NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:")
        let method = try XCTUnwrap(class_getInstanceMethod(WKWebView.self, selector))
        typealias CallMethod = @convention(c) (
            WKWebView, Selector, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Bool, @convention(block) (Any?, Error?) -> Void
        ) -> Void
        var scriptError: Error?
        unsafeBitCast(method_getImplementation(method), to: CallMethod.self)(tab.wkWebView, selector, "return 1", nil, nil, .page, false) { _, error in
            scriptError = error
        }
        XCTAssertNotNil(scriptError, "an extension script on a frozen page fails instead of raising")
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
