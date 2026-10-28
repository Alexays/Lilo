import AppKit
import CryptoKit
import Network
import Security
import WebKit
import XCTest
@testable import Lilo

/// Ordinary validation never launches a capture window or starts a stream.
@MainActor
final class ReleaseCaptureTests: XCTestCase {
    private var fixture: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var server: TinyHTTPServer!
    private var cursor: NSImageView!
    private var cursorPoint = CGPoint(x: 840, y: 530)
    private var recorder: ReleaseWindowRecorder!
    private var output: URL!
    private var activity: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["LILO_RELEASE_CAPTURE_OUT"],
              let pages = ProcessInfo.processInfo.environment["LILO_RELEASE_CAPTURE_FIXTURES"] else { throw XCTSkip("Use make release-media-record") }
        output = URL(fileURLWithPath: path, isDirectory: true)
        previousApplication = NSWorkspace.shared.frontmostApplication
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Recording native release demonstrations")
        let pagesURL = URL(fileURLWithPath: pages, isDirectory: true)
        let identityPath = try XCTUnwrap(ProcessInfo.processInfo.environment["LILO_RELEASE_CAPTURE_IDENTITY"])
        var imported: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: identityPath)) as CFData, [kSecImportExportPassphrase as String: "fixture-only", kSecImportToMemoryOnly as String: true] as CFDictionary, &imported)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let item = try XCTUnwrap((imported as? [[String: Any]])?.first)
        let identity = item[kSecImportItemIdentity as String] as! SecIdentity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(try XCTUnwrap(certificate)) as Data).map { String(format: "%02x", $0) }.joined()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        server = try await TinyHTTPServer(tls: tls) { request in
            let name = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard ["/guide.html", "/notes.html", "/call.html"].contains(name),
                  let data = try? Data(contentsOf: pagesURL.appendingPathComponent(String(name.dropFirst()))) else {
                return ("404 Not Found", ["Content-Type: text/plain"], Data("Not found".utf8))
            }
            return ("200 OK", ["Content-Type: text/html; charset=utf-8"], data)
        }
        fixture = try await TemporaryBrowserContext()
        let context = fixture.context
        context.settingsStore.set("onboardingCompleted", value: "true")
        context.settingsStore.didPromptDefaultBrowser = true
        context.settingsStore.set("addressPlacement", value: "page")
        controller = MainWindowController(context: context)
        context.windows.add(controller)
        controller.window?.setContentSize(NSSize(width: 1120, height: 720))
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.restoreWindowChromeState()
        controller.setupBridgeEarly()
        controller.setupViews()
        controller.setupBridgeLate()
        controller.setupTabShare()
        // Trust exactly this ephemeral fixture certificate inside the isolated test controller.
        controller.insecureTrustExceptions["localhost:\(server.port)"] = fingerprint
        keepRendering(controller.chromeWebView)
        let profile = try context.profileManager.createProfile(name: "Studio")
        let space = try context.spaceManager.createSpace(name: "Studio", profileId: profile.id)
        controller.switchToSpace(space.id)
        controller.applyTabLayout(TabLayout(position: .left, address: .page), animated: false)
        controller.didCompleteSessionRestore = true
        controller.loadChromeUI()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.bridgeRouter.isSilenced = false
        let ready = await pollUntil(timeout: 15) { self.controller.didChromeVisualReady }
        XCTAssertTrue(ready, "Production chrome did not become ready")
        guard ready else {
            let state = try? await controller.chromeWebView.evaluateJavaScript("JSON.stringify({ready:document.readyState,body:document.body.innerText,app:document.querySelector('#app')?.outerHTML.slice(0,1000)})")
            print("Capture chrome diagnostic:", state ?? "unavailable", controller.didReceiveChromeReady, controller.hasDispatchedChromeInitialState)
            throw CocoaError(.fileReadUnknown)
        }
        cursor = NSImageView(image: NSCursor.arrow.image)
        cursor.wantsLayer = true
        cursor.frame.size = NSCursor.arrow.image.size
        controller.window?.contentView?.addSubview(cursor, positioned: .above, relativeTo: nil)
        placeCursor(cursorPoint)
    }

    override func tearDown() async throws {
        await recorder?.cancel()
        controller?.teardownTabShare()
        controller?.pagePopups.values.forEach { $0.close() }
        fixture?.tearDown()
        fixture = nil; controller = nil; server = nil; cursor = nil; recorder = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        previousApplication?.activate()
        previousApplication = nil
        try await super.tearDown()
    }

    func testPeek() async throws {
        let tab = try await open("guide.html")
        let page = try XCTUnwrap(controller.tabManager.activeEngineTab?.wkWebView)
        try await begin("peek")
        try await hold(500)
        try await click("#peek-link", in: page, modifiers: .shift)
        let opened = await pollUntil { self.controller.pagePopups.values.first?.engine.currentTitle == "Field notes" }
        try recorder.checkpoint("peek-open", passed: opened && controller.tabManager.activeOpenTabId == tab.id)
        try await hold(1500)
        let peek = try XCTUnwrap(controller.pagePopups.values.first?.peekView)
        let close = try XCTUnwrap(descendants(peek).compactMap { $0 as? NSButton }.first { $0.toolTip == "Close".localized })
        let closePoint = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: controller.window?.contentView)
        try await glide(to: CGPoint(x: closePoint.x, y: 720 - closePoint.y))
        try await hold(140)
        close.performClick(nil)
        try await hold(650)
        try recorder.checkpoint("source-preserved", passed: controller.pagePopups.isEmpty && controller.tabManager.activeOpenTabId == tab.id)
        try await click("#peek-link", in: page, modifiers: .shift)
        let reopened = await pollUntil { self.controller.pagePopups.values.first?.engine.currentTitle == "Field notes" }
        try recorder.checkpoint("peek-reopened", passed: reopened)
        try await hold(1300)
        try await recorder.finish(scenario: "peek")
    }

    func testAddressBar() async throws {
        _ = try await open("notes.html")
        controller.applyTabLayout(TabLayout(position: .left, address: .page), animated: false)
        try await begin("address-bar")
        try await hold(600)
        controller.openSettings(nil)
        let settings = await pollUntil { (try? await self.controller.chromeWebView.evaluateJavaScript("!!document.querySelector('.section-nav-button')")) as? Bool == true }
        XCTAssertTrue(settings)
        try await click(".section-nav-button", in: controller.chromeWebView, text: "Appearance")
        let appearance = await pollUntil(timeout: 3) { (try? await self.controller.chromeWebView.evaluateJavaScript("[...document.querySelectorAll('[role=radio]')].some(e => e.textContent.trim() === 'Hidden')")) as? Bool == true }
        if !appearance { print("Capture settings diagnostic:", try await controller.chromeWebView.evaluateJavaScript("document.body.innerText")) }
        try await click("[role='radio']", in: controller.chromeWebView, text: "Hidden")
        try await hold(500)
        await AgentInput.key(controller.chromeWebView, chord: "Escape")
        try await hold(700)
        try recorder.checkpoint("address-hidden", passed: controller.tabLayout.address == .hidden)
        try await hold(900)
        controller.bridgeRouter.send(event: "openCommandBar", data: ["newTab": false])
        let command = await pollUntil { (try? await self.controller.chromeWebView.evaluateJavaScript("!!document.querySelector('.command-bar-input')")) as? Bool == true }
        try recorder.checkpoint("command-bar-available", passed: command)
        try await hold(1100)
        await AgentInput.key(controller.chromeWebView, chord: "Escape")
        try await hold(750)
        try await recorder.finish(scenario: "address-bar")
    }

    func testTabShare() async throws {
        let guide = try await open("guide.html")
        let notes = try await open("notes.html")
        _ = try await open("call.html")
        let requester = try XCTUnwrap(controller.tabManager.activeEngineTab?.wkWebView)
        try await begin("tab-share")
        try await hold(500)
        try await click("#share", in: requester)
        let picker = await pollUntil { !self.controller.pendingTabSharePickerRequests.isEmpty }
        try recorder.checkpoint("picker-open", passed: picker)
        try await click("[data-share-tab-id='\(guide.id.uuidString)']", in: controller.chromeWebView)
        try await hold(450)
        try await click(".tab-share-btn.primary", in: controller.chromeWebView)
        let started = await pollUntil { self.controller.tabShareSessions.tabShare(requestedBy: requester)?.engineId == guide.id }
        try recorder.checkpoint("tab-shared", passed: started)
        let received = await pollUntil(timeout: 8) { (try? await requester.evaluateJavaScript("document.querySelector('video').videoWidth > 0")) as? Bool == true }
        try recorder.checkpoint("stream-delivered", passed: received)
        try await hold(800)
        try await click(".tab-item[data-tab-id='\(notes.id.uuidString)']", in: controller.chromeWebView)
        try await hold(450)
        let notesView = try XCTUnwrap(controller.tabManager.engineTab(for: notes.id)?.view)
        try recorder.checkpoint("shown-tab-active", passed: notesView.isDescendant(of: controller.contentContainerView))
        try await click(".share-instead", in: controller.chromeWebView)
        let switched = await pollUntil { self.controller.tabShareSessions.tabShare(requestedBy: requester)?.engineId == notes.id }
        try recorder.checkpoint("share-switched", passed: switched)
        try await hold(1000)
        try await click(".share-row .call-btn", in: controller.chromeWebView)
        let stopped = await pollUntil { self.controller.tabShareSessions.tabShare(requestedBy: requester) == nil }
        try recorder.checkpoint("share-stopped", passed: stopped)
        try await hold(650)
        try await recorder.finish(scenario: "tab-share")
    }

    private func open(_ name: String) async throws -> Tab {
        let url = try XCTUnwrap(URL(string: "https://localhost:\(server.port)/\(name)"))
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: url))
        if let engine = controller.tabManager.engineTab(for: tab.id) { keepRendering(engine.wkWebView) }
        let loaded = await pollUntil(timeout: 25) { self.controller.tabManager.engineTab(for: tab.id)?.isLoading == false && self.controller.tabManager.engineTab(for: tab.id)?.currentTitle?.isEmpty == false }
        guard loaded else {
            let engine = controller.tabManager.engineTab(for: tab.id)
            print("Capture page diagnostic:", name, engine?.currentURL as Any, engine?.currentTitle as Any, engine?.isLoading as Any, try? await engine?.wkWebView.evaluateJavaScript("document.body.innerText"))
            throw CocoaError(.fileReadUnknown)
        }
        return tab
    }

    private func begin(_ scenario: String) async throws {
        try await hold(400)
        recorder = try ReleaseWindowRecorder(directory: output.appendingPathComponent(scenario))
        try await recorder.start(window: XCTUnwrap(controller.window))
    }

    private func hold(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

    private func keepRendering(_ view: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard view.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(view.method(for: selector), to: Setter.self)(view, selector, false)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func placeCursor(_ point: CGPoint) {
        cursorPoint = point
        cursor.frame.origin = CGPoint(x: point.x, y: 720 - point.y - cursor.frame.height)
        cursor.displayIfNeeded()
        CATransaction.flush()
    }

    private func glide(to target: CGPoint) async throws {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cursor.animator().setFrameOrigin(CGPoint(x: target.x, y: 720 - target.y - cursor.frame.height))
        }, completionHandler: nil)
        cursorPoint = target
        CATransaction.flush()
        try await hold(650)
    }

    private func click(_ selector: String, in view: WKWebView, modifiers: NSEvent.ModifierFlags = [], text: String = "") async throws {
        let settled = await pollUntil(timeout: 3) { (try? await view.evaluateJavaScript("document.getAnimations().filter(a => a.effect?.getComputedTiming().iterations !== Infinity).every(a => a.playState !== 'running')")) as? Bool == true }
        XCTAssertTrue(settled, "The control must stop moving before the pointer approaches")
        let rect = try await view.callAsyncJavaScript("""
            const e = [...document.querySelectorAll(selector)].find(e => !text || e.textContent.trim() === text);
            if (!e) throw new Error('Missing control: ' + selector);
            let r = e.getBoundingClientRect();
            if (r.top < 0 || r.bottom > innerHeight) {
                e.scrollIntoView({block: 'center', behavior: 'smooth'});
                let previous = r.top, stable = 0;
                for (let i = 0; i < 90 && stable < 4; i++) {
                    await new Promise(resolve => requestAnimationFrame(resolve));
                    const top = e.getBoundingClientRect().top;
                    stable = Math.abs(top - previous) < 0.1 ? stable + 1 : 0;
                    previous = top;
                }
                r = e.getBoundingClientRect();
            }
            if (r.top < 0 || r.bottom > innerHeight) throw new Error('Control is outside the capture window: ' + selector);
            return {x: r.x + r.width / 2, y: r.y + r.height / 2};
            """, arguments: ["selector": selector, "text": text], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(rect as? [String: Double])
        let point = CGPoint(x: try XCTUnwrap(values["x"]), y: try XCTUnwrap(values["y"]))
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let windowPoint = view.convert(local, to: controller.window?.contentView)
        try await glide(to: CGPoint(x: windowPoint.x, y: 720 - windowPoint.y))
        try await hold(140)
        AgentInput.mouseEvent(.leftMouseDown, view, at: point, clickCount: 1, modifiers: modifiers)
        try await hold(80)
        AgentInput.mouseEvent(.leftMouseUp, view, at: point, clickCount: 1, modifiers: modifiers)
        try await hold(180)
    }
}
