import AppKit
import XCTest
@testable import Lilo

@MainActor
final class ReleaseMediaCaptureTests: XCTestCase {
    func testReviewBundledWhatsNewMedia() async throws {
        guard let version = ProcessInfo.processInfo.environment["LILO_RELEASE_MEDIA_REVIEW_VERSION"] else {
            throw XCTSkip("Opt-in actual native What's New media review")
        }
        let capture = try await ReleaseMediaCapture(version: "review", feature: "review")
        defer { capture.close() }
        var playbackQuality: [String: Any] = [:]
        try await capture.page()
        capture.controller.bridgeRouter.send(event: "openWhatsNew", data: ["version": version, "automatic": false])
        try await capture.wait("actual native What's New opens with the selected release") { await capture.exists(".whats-new .release-media") }
        if await capture.exists(".whats-new video") {
            _ = try await capture.chrome.evaluateJavaScript("document.querySelector('.whats-new video').load();undefined")
            try await capture.wait("bundled MP4 decodes from Lilo's private origin") {
                (try? await capture.chrome.evaluateJavaScript("document.querySelector('.whats-new video').readyState>=2")) as? Bool == true
            }
            _ = try await capture.chrome.callAsyncJavaScript("await document.querySelector('.whats-new video').play();return true", arguments: [:], in: nil, contentWorld: .page)
            try await capture.wait("native MP4 playback advances with sound") {
                (try? await capture.chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video');return v.currentTime>.2&&v.controls&&!v.muted&&v.audioTracks.length>0})()")) as? Bool == true
            }
            try await capture.wait("native MP4 playback stays smooth") {
                (try? await capture.chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video'),q=v.getVideoPlaybackQuality();return v.currentTime>=1.8&&(q.totalVideoFrames-q.droppedVideoFrames)/v.currentTime>=54&&q.droppedVideoFrames/Math.max(1,q.totalVideoFrames)<.03})()")) as? Bool == true
            }
            let quality = try await capture.chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video'),q=v.getVideoPlaybackQuality();return {seconds:v.currentTime,totalFrames:q.totalVideoFrames,droppedFrames:q.droppedVideoFrames,presentedFps:(q.totalVideoFrames-q.droppedVideoFrames)/v.currentTime}})()")
            playbackQuality = quality as? [String: Any] ?? [:]
            _ = try await capture.chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video');v.pause();v.currentTime=v.duration*.88})();undefined")
            try await capture.wait("native MP4 seeking completes") {
                (try? await capture.chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video');return !v.seeking&&Math.abs(v.currentTime-v.duration*.88)<.05})()")) as? Bool == true
            }
        } else {
            try await capture.wait("native release still loads losslessly") {
                (try? await capture.chrome.evaluateJavaScript("document.querySelector('.release-media img')?.naturalWidth===1920")) as? Bool == true
            }
        }
        try await capture.window("whats-new-\(version)")
        try capture.finish(checks: ["actualNativeWhatsNew": true, "reviewedRelease": version, "actualBinaryVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "playbackQuality": playbackQuality])
    }

    func testAddressBarAnnouncement() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.8.0-announcement", feature: "address-bar")
        defer { capture.close() }
        capture.context.settingsStore.set("addressPlacement", value: "page")
        capture.controller.applyStoredTabLayoutEverywhere()
        let tab = try await capture.page(title: "Field guide", color: "#553f69")
        let engine = try XCTUnwrap(capture.controller.tabManager.engineTab(for: tab.id))
        try await capture.wait("native page toolbar is visible") {
            let address = try? await capture.chrome.evaluateJavaScript("document.documentElement.dataset.address")
            return capture.controller.tabLayout.address == .page && address as? String == "page"
        }
        try await capture.window("address-visible")
        let visibleHeight = capture.controller.contentContainerView.frame.height
        capture.controller.openSettings(nil)
        try await capture.wait("native Settings navigation opens") { await capture.exists(".section-nav-button") }
        try await capture.click(".section-nav-button", text: "Appearance")
        let selector = ".ui-list-row:has(.ui-segmented[aria-label='Address'])"
        try await capture.wait("Appearance contains the real address setting") { await capture.exists(selector) }
        try await capture.region(selector, name: "setting-visible", margin: 10)
        try await capture.click(".ui-segmented[aria-label='Address'] button", text: "Hidden")
        try await capture.wait("Hidden persists through the real Settings bridge") {
            capture.context.settingsStore.tabLayout.address == .hidden && capture.controller.tabLayout.address == .hidden
        }
        try await capture.region(selector, name: "setting-hidden", margin: 10)
        try await capture.click(".section-nav-panel .panel-close")
        try await capture.wait("native address is hidden and the page remains loaded") {
            let address = try? await capture.chrome.evaluateJavaScript("document.documentElement.dataset.address")
            let title = try? await engine.wkWebView.evaluateJavaScript("document.title")
            return address as? String == "hidden" && title as? String == "Field guide"
        }
        try await capture.window("address-hidden")
        let hiddenHeight = capture.controller.contentContainerView.frame.height
        XCTAssertGreaterThan(hiddenHeight, visibleHeight)
        capture.controller.focusChrome()
        capture.controller.bridgeRouter.send(event: "openCommandBar", data: ["newTab": false])
        try await capture.wait("command bar remains available with the address hidden") { await capture.exists(".command-bar") }
        try capture.finish(checks: ["actualSettingsBridge": true, "addressPlacementBefore": "page", "addressPlacementAfter": "hidden",
                                    "pageTitle": "Field guide", "pageHeightBefore": visibleHeight, "pageHeightAfter": hiddenHeight,
                                    "commandBarWithAddressHidden": true])
    }

    func testTabShareSearchAndSwitch() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.8.0", feature: "tab-share")
        defer { capture.close() }
        let first = try await capture.page(title: "Field guide")
        let second = try await capture.page(title: "Studio notes")
        let call = try await capture.callPage()
        let requester = try XCTUnwrap(capture.controller.tabManager.engineTab(for: call.id)).wkWebView
        let pick = Task { await capture.controller.presentTabSharePicker(origin: "https://example.com", requester: requester, allowsSystem: false) }
        defer { pick.cancel() }
        try await capture.wait("actual native tab picker opens") { await capture.exists(".tab-share-panel") }
        try await capture.region(".tab-share-panel", name: "picker", margin: 0)
        for (index, query) in ["", "F", "Fi", "Fie", "Fiel", "Field"].enumerated() {
            try await capture.input(".tab-share-search input", value: query)
            try await capture.region(".tab-share-search", name: "search-\(index)", margin: 0)
        }
        try await capture.wait("actual native picker filters tabs") {
            (try? await capture.chrome.evaluateJavaScript("document.querySelectorAll('.tab-share-card').length===1 && document.querySelector('.tab-share-card-title')?.textContent==='Field guide'")) as? Bool == true
        }
        try await capture.region(".tab-share-panel", name: "filtered", margin: 0)
        try await capture.region(".tab-share-card", name: "match", margin: 0)
        try await capture.click(".tab-share-btn.primary")
        let choice = await pick.value
        XCTAssertEqual(choice, .tab(first.id))
        let payload = try XCTUnwrap(capture.controller.startTabShare(tabId: first.id, requester: requester))
        let token = try XCTUnwrap(payload["token"] as? String)
        try await capture.click(".tab-item[data-tab-id='\(second.id.uuidString)']")
        try await capture.wait("share shown tab action appears") { await capture.exists(".share-instead") }
        try await capture.region(".call-card", name: "sharing", margin: 0)
        try await capture.click(".share-instead")
        try await capture.wait("real share session changed source without replacing its token") {
            let share = capture.controller.tabShareSessions.share(requestedBy: requester)
            return share?.engineId == second.id && share?.token == token
        }
        try await capture.region(".call-card", name: "switched", margin: 0)
        capture.controller.stopTabShare(token: token)
        try capture.finish(checks: ["pickerSearch": "Field", "nativeShareSourceChanged": true, "shareTokenPreserved": true, "realMediaSessionHandlers": true, "syntheticDeviceUsage": true])
    }
}
