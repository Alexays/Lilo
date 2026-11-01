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
            _ = try await capture.chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video');v.pause();v.currentTime=Math.min(4.5,v.duration/2)})();undefined")
            try await capture.wait("native MP4 seeking completes") {
                (try? await capture.chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video');return !v.seeking&&Math.abs(v.currentTime-Math.min(4.5,v.duration/2))<.05})()")) as? Bool == true
            }
        } else {
            try await capture.wait("native release still loads losslessly") {
                (try? await capture.chrome.evaluateJavaScript("document.querySelector('.release-media img')?.naturalWidth===1920")) as? Bool == true
            }
        }
        try await capture.window("whats-new-\(version)")
        try capture.finish(checks: ["actualNativeWhatsNew": true, "reviewedRelease": version, "actualBinaryVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? ""])
    }
    func testSpacesMaterialAndColor() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.11.0", feature: "spaces")
        defer { capture.close() }
        try await capture.page()
        try await capture.window("solid-window")
        capture.controller.editCurrentSpace(nil)
        try await capture.wait("Space editor opens") {
            (try? await capture.chrome.evaluateJavaScript("!!document.querySelector('.appearance-row')")) as? Bool == true
        }
        try await capture.click(".appearance-row")
        try await capture.wait("native appearance controls open") {
            (try? await capture.chrome.evaluateJavaScript("!!document.querySelector('.appearance-card .materials')")) as? Bool == true
        }
        try await capture.region(".appearance-card", name: "solid-editor")
        try await capture.region(".materials", name: "solid-controls", margin: 0)
        for material in ["Glass", "Grain"] {
            try await capture.click(".material", text: material)
            try await capture.wait("actual preview uses \(material)") {
                (try? await capture.chrome.evaluateJavaScript("!!document.querySelector('.win.\(material.lowercased())')")) as? Bool == true
            }
            try await capture.region(".appearance-card", name: "\(material.lowercased())-editor")
            try await capture.region(".materials", name: "\(material.lowercased())-controls", margin: 0)
            try await capture.click(".footer-actions button", text: "Save")
            try await capture.wait("\(material) is saved through the native Space bridge") {
                capture.context.spaceManager.space(with: capture.space.id)?.material == material.lowercased()
            }
            try await capture.window("\(material.lowercased())-window")
            if material == "Glass" {
                capture.controller.editCurrentSpace(nil)
                try await capture.wait("Space editor reopens") {
                    (try? await capture.chrome.evaluateJavaScript("!!document.querySelector('.appearance-row')")) as? Bool == true
                }
                try await capture.click(".appearance-row")
                try await capture.wait("appearance controls reopen") {
                    (try? await capture.chrome.evaluateJavaScript("!!document.querySelector('.appearance-card .materials')")) as? Bool == true
                }
            }
        }
        let second = try capture.context.spaceManager.createSpace(name: "Studio", icon: "🎨", color: "#c48d78", material: "glass", profileId: capture.space.profileId)
        capture.controller.switchToSpace(second.id)
        try await capture.page(title: "Room to create", color: "#6e493f")
        try await capture.window("glass-space")
        try capture.finish(checks: ["savedMaterial": "grain", "secondSpaceMaterial": "glass", "separateSpaceIds": second.id != capture.space.id])
    }

    func testHolidayIconsStill() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.13.0", feature: "seasons")
        defer { capture.close() }
        for season in ["halloween", "christmas", "newyear", "valentine", "lunar", "easter", "summer", "birthday"] {
            try capture.bundledArtwork(season: season)
        }
        try capture.finish(checks: ["nativeSeasonalArtworkCount": 8, "medium": "screenshot", "animationNeeded": false])
    }

    func testFirstPublicBrowserStill() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.1.0", feature: "browser")
        defer { capture.close() }
        try await capture.page(title: "A place to begin")
        try await capture.window("browser")
        try capture.finish(checks: ["syntheticContent": true, "medium": "screenshot"])
    }

    func testTabEdges() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.2.0", feature: "tab-edges")
        defer { capture.close() }
        try await capture.page(title: "Field guide")
        try await capture.page(title: "Studio notes")
        for position in TabPosition.allCases {
            capture.controller.setTabPosition(position)
            try await capture.wait("native tab layout is \(position)") { capture.controller.tabLayout.position == position }
            try await capture.window(position.rawValue)
        }
        try capture.finish(checks: ["nativeTabPositions": TabPosition.allCases.map(\.rawValue)])
    }

    func testSettingsPageStill() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.3.0", feature: "settings")
        defer { capture.close() }
        try await capture.page()
        capture.controller.setTabPosition(.top)
        capture.controller.openSettings(nil)
        try await capture.wait("native Settings opens") { await capture.exists(".ui-shell-frame") }
        try await capture.region(".ui-shell-frame", name: "settings", scale: 2, margin: 0)
        try await capture.window("settings-window")
        try capture.finish(checks: ["nativeSettingsCommand": true, "medium": "screenshot"])
    }

    func testUpdateCardStill() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.4.0", feature: "updates")
        defer { capture.close() }
        try await capture.page()
        capture.controller.bridgeRouter.send(event: "updateReady", data: ["version": "0.4.0"])
        try await capture.wait("actual downloaded-update card appears") { await capture.exists(".update-card") }
        try await capture.region(".update-dock", name: "updates", margin: 10)
        try capture.finish(checks: ["fixtureInput": "Synthetic updateReady event; no real update downloaded or installed", "medium": "screenshot"])
    }

    func testUnreadStill() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.6.0", feature: "unread")
        defer { capture.close() }
        try await capture.page(title: "(3) Studio mail")
        try await capture.page(title: "(12) Team chat")
        try await capture.page(title: "Field notes")
        try await capture.wait("native unread count is rendered") { await capture.exists(".unread-count") }
        try await capture.region(".tab-item, .new-tab-line", name: "unread", scale: 6, margin: 8)
        try capture.finish(checks: ["unreadSource": "Actual generic title unread detection on owned fixture pages", "medium": "screenshot"])
    }

    func testHistorySearch() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.9.0", feature: "history")
        defer { capture.close() }
        try await capture.page()
        let history = try capture.context.profileContexts.context(for: capture.space.profileId).history
        for (path, title) in [("research/field-guide", "Field guide"), ("studio/notes", "Studio notes"), ("studio/references", "Studio references"), ("research/ideas", "New ideas")] {
            try history.recordVisit(url: "https://example.com/\(path)", title: title)
        }
        capture.controller.openHistory(nil)
        try await capture.wait("native History opens") { await capture.exists(".history-search input") }
        try await capture.region(".ui-shell-frame", name: "history", scale: 3, margin: 0)
        try await capture.region(".history-search input", name: "search-empty", margin: 6)
        try await capture.input(".history-search input", value: "Studio")
        try await capture.wait("native history filters the real store") {
            (try? await capture.chrome.evaluateJavaScript("document.querySelector('.days')?.textContent.includes('Studio notes') && !document.querySelector('.days')?.textContent.includes('Field guide')")) as? Bool == true
        }
        try await capture.region(".ui-shell-frame", name: "filtered", scale: 3, margin: 0)
        try await capture.region(".history-search input", name: "search", margin: 6)
        try capture.finish(checks: ["nativeHistoryStoreVisits": 4, "query": "Studio", "filteredOut": "Field guide"])
    }

    func testArchiveRestore() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.10.0", feature: "archive")
        defer { capture.close() }
        try await capture.page()
        let entry = TabArchive.Entry(spaceId: capture.space.id, url: URL(string: "https://example.com/field-guide")!, title: "Field guide")
        capture.context.tabArchive.add(entry)
        capture.controller.sendArchivedTabs()
        try await capture.wait("native archive button appears") { await capture.exists(".archive-button") }
        try await capture.region(".tab-item, .new-tab-line", name: "before", scale: 6, margin: 8)
        try await capture.click(".archive-button")
        try await capture.wait("native archive menu opens") { await capture.exists(".menu-row:not(.show-all)") }
        try await capture.region(".strip-popover", name: "archive", margin: 8)
        try await capture.click(".menu-row:not(.show-all)")
        try await capture.wait("real native archive entry was restored") { !capture.context.tabArchive.entries.contains(where: { $0.id == entry.id }) }
        let restored = try XCTUnwrap(capture.controller.tabManager.openTabs.first { $0.url == entry.url })
        try await capture.loadPage(in: restored, title: entry.title, url: entry.url)
        try await capture.region(".tab-item, .new-tab-line", name: "restored", scale: 6, margin: 8)
        try capture.finish(checks: ["restoredNativeArchiveEntry": true])
    }

    func testSiteColorsStill() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.12.0", feature: "site-colors")
        defer { capture.close() }
        capture.context.settingsStore.set("addressPlacement", value: "page")
        capture.controller.applyStoredTabLayoutEverywhere()
        try await capture.page(title: "A calmer workspace", color: "#553f69")
        try await capture.window("site-colors")
        try capture.finish(checks: ["addressPlacement": "page", "ownedSiteThemeColor": "#553f69", "medium": "screenshot"])
    }

    func testCallControlsWhileBrowsing() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.7.0", feature: "calls")
        defer { capture.close() }
        let call = try await capture.callPage()
        let engine = try XCTUnwrap(capture.controller.tabManager.engineTab(for: call.id))
        try await capture.page(title: "Field notes")
        try await capture.wait("native call card remains while browsing") { await capture.exists(".call-card") }
        try await capture.region(".call-card", name: "connected", margin: 0)
        try await capture.window("browsing")
        try await capture.click(".call-controls .call-btn[aria-label='Mute microphone']")
        try await capture.wait("native mute reached the real page handler") { engine.callControls.microphoneActive == false }
        try await capture.region(".call-card", name: "muted", margin: 0)
        try await capture.click(".call-controls .call-btn[aria-label='Turn off camera']")
        try await capture.wait("native camera control reached the real page handler") { engine.callControls.cameraActive == false }
        try await capture.region(".call-card", name: "camera-off", margin: 0)
        try capture.finish(checks: ["realMediaSessionHandlers": true, "syntheticDeviceUsage": true, "hardwareOrRemoteCallUsed": false])
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
        try await capture.region(".tab-share-panel", name: "picker", scale: 3, margin: 0)
        try await capture.region(".tab-share-search", name: "search-empty", margin: 0)
        try await capture.input(".tab-share-search input", value: "Field")
        try await capture.wait("actual native picker filters tabs") {
            (try? await capture.chrome.evaluateJavaScript("document.querySelectorAll('.tab-share-card').length===1 && document.querySelector('.tab-share-card-title')?.textContent==='Field guide'")) as? Bool == true
        }
        try await capture.region(".tab-share-panel", name: "filtered", scale: 3, margin: 0)
        try await capture.region(".tab-share-search", name: "search", margin: 0)
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

    func testPinnedTabRename() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.1.3", feature: "pinned-tabs")
        defer { capture.close() }
        let tab = try await capture.page(title: "Field guide")
        capture.controller.pinCurrentTab(nil)
        try await capture.wait("native pinned tab appears") { await capture.exists(".pinned-section .tab-title") }
        try await capture.region(".pinned-section", name: "pinned", margin: 0)
        _ = try await capture.chrome.evaluateJavaScript("document.querySelector('.pinned-section .tab-title').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));undefined")
        try await capture.wait("native rename input opens") { await capture.exists(".tab-title-input") }
        try await capture.input(".tab-title-input", value: "Studio")
        try await capture.region(".pinned-section", name: "renaming", margin: 0)
        _ = try await capture.chrome.evaluateJavaScript("document.querySelector('.tab-title-input').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));undefined")
        try await capture.wait("native rename is saved") { capture.controller.tabManager.tab(for: tab.id)?.customTitle == "Studio" }
        try await capture.region(".pinned-section", name: "renamed", margin: 0)
        try capture.finish(checks: ["nativePinnedTab": true, "customTitle": "Studio", "realRenameInput": true])
    }

    func testDropLinkInSidebar() async throws {
        let capture = try await ReleaseMediaCapture(version: "0.14.0", feature: "drop")
        defer { capture.close() }
        try await capture.page(title: "Studio notes")
        try await capture.page(title: "Field guide")
        try await capture.region(".tab-item, .new-tab-line", name: "before", scale: 6, margin: 8)
        capture.controller.bridgeRouter.send(event: "linkDrag", data: ["urls": ["https://example.com/new-idea"], "text": ""])
        try await capture.settled()
        _ = try await capture.chrome.evaluateJavaScript("""
            window.fixtureDrag=new DataTransfer();window.fixtureDrag.setData('text/uri-list','https://example.com/new-idea');
            const r=document.querySelectorAll('.tab-list .tab-item')[1].getBoundingClientRect();
            window.fixtureDragPoint={x:r.x+r.width/2,y:r.y+1};
            window.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:window.fixtureDrag,clientX:window.fixtureDragPoint.x,clientY:window.fixtureDragPoint.y}));undefined;
            """)
        try await capture.wait("actual native link insertion indicator appears") { await capture.exists(".sidebar-link-drop") }
        try await capture.region(".tab-item, .new-tab-line", name: "target", scale: 6, margin: 8)
        _ = try await capture.chrome.evaluateJavaScript("window.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:window.fixtureDrag,clientX:window.fixtureDragPoint.x,clientY:window.fixtureDragPoint.y}));undefined")
        try await capture.wait("production bridge opens the dropped link") {
            capture.controller.tabManager.openTabs.contains { $0.url?.absoluteString == "https://example.com/new-idea" }
        }
        let dropped = try XCTUnwrap(capture.controller.tabManager.openTabs.first { $0.url?.absoluteString == "https://example.com/new-idea" })
        try await capture.loadPage(in: dropped, title: "New idea", url: URL(string: "https://example.com/new-idea")!)
        try await capture.region(".tab-item, .new-tab-line", name: "dropped", scale: 6, margin: 8)
        try capture.finish(checks: ["syntheticExternalDragPayload": true, "actualNativeDropIndicator": true, "actualBrowserCommandOpenedLink": true])
    }
}
