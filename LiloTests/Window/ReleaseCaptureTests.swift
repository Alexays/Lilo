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
    private var authoredScenario: AuthoredReleaseScenario?
    private var authoredDigest: String?
    private var previousMenu: NSMenu?

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["LILO_RELEASE_CAPTURE_OUT"],
              let pages = ProcessInfo.processInfo.environment["LILO_RELEASE_CAPTURE_FIXTURES"] else { throw XCTSkip("Use make release-media-record") }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "Unlock macOS before recording native release media"])
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        previousApplication = NSWorkspace.shared.frontmostApplication
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Recording native release demonstrations")
        let pagesURL = URL(fileURLWithPath: pages, isDirectory: true)
        if let file = ProcessInfo.processInfo.environment["LILO_RELEASE_SCENARIO_FILE"], !file.isEmpty {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            authoredScenario = try JSONDecoder().decode(AuthoredReleaseScenario.self, from: data)
            authoredDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let authoredPages = Dictionary(uniqueKeysWithValues: (authoredScenario?.fixtures ?? []).map { ($0.name, Data((authoredScenario?.fixtures ?? []).reduce($0.html) { html, page in html.replacingOccurrences(of: "{{fixture:\(page.name)}}", with: page.name) }.utf8)) })
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
            let filename = String(name.dropFirst())
            let data = authoredPages[filename] ?? (["/guide.html", "/notes.html", "/call.html"].contains(name) ? try? Data(contentsOf: pagesURL.appendingPathComponent(filename)) : nil)
            guard let data else {
                return ("404 Not Found", ["Content-Type: text/plain"], Data("Not found".utf8))
            }
            return ("200 OK", ["Content-Type: text/html; charset=utf-8", "Content-Security-Policy: default-src 'self' data: blob:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; object-src 'none'; base-uri 'none'"], data)
        }
        fixture = try await TemporaryBrowserContext()
        let context = fixture.context
        context.settingsStore.set("onboardingCompleted", value: "true")
        context.settingsStore.didPromptDefaultBrowser = true
        context.settingsStore.set("addressPlacement", value: "page")
        for setting in authoredScenario?.settings ?? [] { context.settingsStore.set(setting.key, value: setting.value) }
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
        if authoredScenario != nil {
            controller.reconcileBootstrapCacheWithDB()
        } else {
            controller.applyTabLayout(TabLayout(position: .left, address: .page), animated: false)
        }
        if authoredScenario != nil {
            previousMenu = NSApp.mainMenu
            (NSApp.delegate as? AppDelegate)?.setupMainMenu()
        }
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
        if let previousMenu { NSApp.mainMenu = previousMenu }
        previousMenu = nil
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

    func testAuthoredScenario() async throws {
        guard let scenario = authoredScenario else { throw XCTSkip("Use SCENARIO=file.json") }
        guard scenario.id.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else { throw CocoaError(.fileReadCorruptFile) }
        var tabs: [String: UUID] = [:]
        do {
            for tab in scenario.tabs { tabs[tab.id] = try await open(tab.page).id }
            try await begin(scenario.id, scenarioDigest: authoredDigest)
            for step in scenario.steps { try await perform(step, tabs: tabs) }
            try await recorder.finish(scenario: scenario.id)
        } catch {
            var diagnostic: [String: Any] = ["error": error.localizedDescription, "menus": menuActions(NSApp.mainMenu)]
            diagnostic["chrome"] = try? await controller.chromeWebView.evaluateJavaScript("document.body.outerHTML.slice(0,16000)")
            if let page = controller.tabManager.activeEngineTab?.wkWebView {
                diagnostic["page"] = try? await page.evaluateJavaScript("document.body.innerText.slice(0,6000)")
            }
            let directory = output.appendingPathComponent(scenario.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("diagnostics.json"))
            throw error
        }
    }

    private func perform(_ step: AuthoredReleaseScenario.Step, tabs: [String: UUID]) async throws {
        switch step.type {
        case "hold": try await hold(try XCTUnwrap(step.durationMs))
        case "menu":
            let name = try XCTUnwrap(step.selector)
            let action = NSSelectorFromString(name)
            guard AuthoredReleaseScenario.menuActions.contains(name), menuActions(NSApp.mainMenu).contains(name), controller.responds(to: action), controller.tryToPerform(action, with: nil) else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Unavailable native menu action: \(name)"])
            }
            try await hold(350)
        case "key":
            let chord = try XCTUnwrap(step.chord)
            guard AuthoredReleaseScenario.keyChords.contains(chord) else { throw CocoaError(.featureUnsupported) }
            await AgentInput.key(try webView(step.surface ?? ""), chord: chord)
        case "click", "type":
            let target = try XCTUnwrap(step.target)
            if target.surface == "native" {
                guard step.type == "click" else { throw CocoaError(.featureUnsupported) }
                let button = try XCTUnwrap(nativeButton(target))
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: controller.window?.contentView)
                try await glide(to: CGPoint(x: point.x, y: 720 - point.y))
                button.performClick(nil)
            } else {
                let view = try webView(target.surface)
                var modifiers: NSEvent.ModifierFlags = []
                for name in step.modifiers ?? [] {
                    switch name { case "shift": modifiers.insert(.shift); case "command": modifiers.insert(.command); case "option": modifiers.insert(.option); case "control": modifiers.insert(.control); default: throw CocoaError(.fileReadCorruptFile) }
                }
                try await click(resolve(target.selector, tabs: tabs), in: view, modifiers: modifiers, text: resolve(target.text, tabs: tabs), right: step.button == "right", count: step.count ?? 1)
                if step.type == "type" {
                    if step.replace == true { await AgentInput.key(view, chord: "cmd+a") }
                    await AgentInput.type(view, text: resolve(try XCTUnwrap(step.text), tabs: tabs))
                }
            }
        case "drag":
            let from = try XCTUnwrap(step.from), to = try XCTUnwrap(step.to)
            guard from.surface == to.surface, from.surface != "native" else { throw CocoaError(.featureUnsupported) }
            let view = try webView(from.surface)
            let start = try await controlPoint(resolve(from.selector, tabs: tabs), in: view, text: resolve(from.text, tabs: tabs))
            let end = try await controlPoint(resolve(to.selector, tabs: tabs), in: view, text: resolve(to.text, tabs: tabs))
            try await moveCursor(to: start, in: view)
            AgentInput.mouseEvent(.leftMouseDown, view, at: start, clickCount: 1, modifiers: [])
            let duration = try XCTUnwrap(step.durationMs)
            for index in 1...24 {
                let t = CGFloat(index) / 24
                let eased = t * t * (3 - 2 * t)
                let point = CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
                let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
                let windowPoint = view.convert(local, to: controller.window?.contentView)
                placeCursor(CGPoint(x: windowPoint.x, y: 720 - windowPoint.y))
                AgentInput.mouseEvent(.leftMouseDragged, view, at: point, clickCount: 1, modifiers: [])
                try await hold(duration / 24)
            }
            AgentInput.mouseEvent(.leftMouseUp, view, at: end, clickCount: 1, modifiers: [])
            try await hold(250)
        case "assert":
            let predicate = try XCTUnwrap(step.predicate)
            let passed = await pollUntil(timeout: 3) { (try? await self.check(predicate, tabs: tabs)) == true }
            try recorder.checkpoint(try XCTUnwrap(step.id), passed: passed)
        default: throw CocoaError(.featureUnsupported)
        }
    }

    private func webView(_ surface: String) throws -> WKWebView {
        switch surface {
        case "chrome": return controller.chromeWebView
        case "page": return try XCTUnwrap(controller.tabManager.activeEngineTab?.wkWebView)
        case "peek": return try XCTUnwrap(controller.pagePopups.values.first?.engine.wkWebView)
        default: throw CocoaError(.featureUnsupported)
        }
    }

    private func resolve(_ value: String, tabs: [String: UUID]) -> String {
        var result = value
        for (name, id) in tabs { result = result.replacingOccurrences(of: "{{tab:\(name)}}", with: id.uuidString) }
        for page in authoredScenario?.fixtures ?? [] { result = result.replacingOccurrences(of: "{{fixture:\(page.name)}}", with: "https://localhost:\(server.port)/\(page.name)") }
        return result
    }

    private func menuActions(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).flatMap { item -> [String] in
            let own = item.action.map { [NSStringFromSelector($0)] } ?? []
            return own + menuActions(item.submenu)
        }
    }

    private func nativeButton(_ target: AuthoredReleaseScenario.Target) -> NSButton? {
        guard let root = controller.window?.contentView else { return nil }
        return descendants(root).compactMap { $0 as? NSButton }.first { button in
            (target.selector == "button" || button.identifier?.rawValue == target.selector || button.toolTip == target.selector)
                && (target.text.isEmpty || button.title == target.text || button.toolTip == target.text || button.accessibilityLabel() == target.text)
                && !button.isHiddenOrHasHiddenAncestor
        }
    }

    private func check(_ predicate: AuthoredReleaseScenario.Predicate, tabs: [String: UUID]) async throws -> Bool {
        switch predicate.kind {
        case "selected-tab": return controller.tabManager.activeOpenTabId == tabs[predicate.tab ?? ""]
        case "shared-tab":
            let engines = controller.tabShareSessions.sharedEngines
            return predicate.tab == "" ? engines.isEmpty : engines.contains { $0.id == tabs[predicate.tab ?? ""] }
        case "peek-count": return controller.pagePopups.count == predicate.equals
        case "setting": return contextSetting(predicate.key ?? "") == predicate.value?.json as? String
        default: break
        }
        let target = try XCTUnwrap(predicate.target)
        if target.surface == "native" {
            guard ["visible", "absent"].contains(predicate.kind) else { throw CocoaError(.featureUnsupported) }
            let button = nativeButton(target)
            if predicate.kind == "absent" { return button == nil }
            return button != nil
        }
        if target.surface == "peek", controller.pagePopups.isEmpty { return predicate.kind == "absent" }
        let view = try webView(target.surface)
        let result = try await view.callAsyncJavaScript("""
            const matches = [...document.querySelectorAll(selector)].filter(e => !text || e.textContent.trim() === text);
            const e = matches[0];
            if (kind === 'count') return matches.length === expectedCount;
            const visible = \(AuthoredReleaseScenario.renderedVisibilitySource);
            if (kind === 'visible') return visible;
            if (kind === 'absent') return !visible;
            if (!e) return false;
            if (kind === 'text') return e.textContent.includes(includes);
            if (kind === 'attribute') return e.getAttribute(name) === value;
            if (kind === 'property') return comparison === 'greater' ? e[name] > value : e[name] === value;
            return false;
            """, arguments: ["selector": resolve(target.selector, tabs: tabs), "text": resolve(target.text, tabs: tabs), "kind": predicate.kind, "includes": predicate.includes ?? "", "expectedCount": predicate.equals ?? 0, "name": predicate.name ?? "", "value": predicate.value?.json ?? NSNull(), "comparison": predicate.comparison ?? "equals"], in: nil, contentWorld: .page)
        return result as? Bool == true
    }

    private func contextSetting(_ key: String) -> String? { fixture.context.settingsStore.get(key) }

    func testPointerMovementUpdatesBrowserHover() async throws {
        _ = try await open("notes.html")
        let chrome = controller.chromeWebView
        let point = try await controlPoint(".nav-btn", in: chrome, text: "")
        try await moveCursor(to: point, in: chrome)
        let entered = await pollUntil { (try? await chrome.evaluateJavaScript("document.querySelectorAll('.nav-btn:hover').length === 1")) as? Bool == true }
        XCTAssertTrue(entered)
        let page = try XCTUnwrap(controller.tabManager.activeEngineTab?.wkWebView)
        try await moveCursor(to: CGPoint(x: 400, y: 200), in: page)
        let exited = await pollUntil { (try? await chrome.evaluateJavaScript("document.querySelectorAll('.nav-btn:hover').length === 0")) as? Bool == true }
        XCTAssertTrue(exited)
    }

    func testNativeMediaSmoke() async throws {
        let tab = try await open("guide.html")
        let page = try XCTUnwrap(controller.tabManager.activeEngineTab?.wkWebView)
        try await begin("native-smoke")
        try await hold(400)
        try await click("#peek-link", in: page, modifiers: .shift)
        let opened = await pollUntil { self.controller.pagePopups.values.first?.engine.currentTitle == "Field notes" }
        try recorder.checkpoint("real-native-peek", passed: opened && controller.tabManager.activeOpenTabId == tab.id)
        try await hold(1400)
        try await recorder.finish(scenario: "native-smoke")
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
        try await hold(2100)
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
        try await hold(2500)
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
        try await hold(1400)
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

    private func begin(_ scenario: String, scenarioDigest: String? = nil) async throws {
        try await hold(400)
        recorder = try ReleaseWindowRecorder(directory: output.appendingPathComponent(scenario), scenarioDigest: scenarioDigest)
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

    private func clearHover() {
        var views: [WKWebView] = [controller.chromeWebView]
        if let page = controller.tabManager.activeEngineTab?.wkWebView { views.append(page) }
        views += controller.pagePopups.values.map { $0.engine.wkWebView }
        for view in views where view.window != nil {
            AgentInput.mouseEvent(.mouseMoved, view, at: CGPoint(x: -20, y: -20), clickCount: 0, modifiers: [])
        }
    }

    private func glide(to target: CGPoint) async throws {
        clearHover()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cursor.animator().setFrameOrigin(CGPoint(x: target.x, y: 720 - target.y - cursor.frame.height))
        }, completionHandler: nil)
        cursorPoint = target
        CATransaction.flush()
        try await hold(650)
    }

    private func controlPoint(_ selector: String, in view: WKWebView, text: String) async throws -> CGPoint {
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
        return CGPoint(x: try XCTUnwrap(values["x"]), y: try XCTUnwrap(values["y"]))
    }

    private func moveCursor(to point: CGPoint, in view: WKWebView) async throws {
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let windowPoint = view.convert(local, to: controller.window?.contentView)
        try await glide(to: CGPoint(x: windowPoint.x, y: 720 - windowPoint.y))
        AgentInput.mouseEvent(.mouseMoved, view, at: point, clickCount: 0, modifiers: [])
    }

    private func click(_ selector: String, in view: WKWebView, modifiers: NSEvent.ModifierFlags = [], text: String = "", right: Bool = false, count: Int = 1) async throws {
        let point = try await controlPoint(selector, in: view, text: text)
        try await moveCursor(to: point, in: view)
        try await hold(140)
        AgentInput.mouseEvent(right ? .rightMouseDown : .leftMouseDown, view, at: point, clickCount: count, modifiers: modifiers)
        try await hold(80)
        AgentInput.mouseEvent(right ? .rightMouseUp : .leftMouseUp, view, at: point, clickCount: count, modifiers: modifiers)
        try await hold(180)
    }
}


@MainActor
final class AuthoredReleaseVisibilityTests: XCTestCase {
    func testVisibilityRequiresBothViewportAxesAndVisibleAncestors() async throws {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.loadHTMLString("""
            <title>Visibility</title><style>.sample{position:absolute;top:20px;left:20px;width:30px;height:30px}</style>
            <div id="shown" class="sample">Visible</div>
            <div id="left" class="sample" style="left:-400px">Left</div>
            <div id="right" class="sample" style="left:600px">Right</div>
            <div id="below" class="sample" style="top:600px">Below</div>
            <section style="opacity:0"><div id="transparent" class="sample">Hidden</div></section>
            """, baseURL: nil)
        let ready = await pollUntil { (try? await view.evaluateJavaScript("document.title === 'Visibility' && !!document.querySelector('#transparent')")) as? Bool == true }
        XCTAssertTrue(ready)
        for (id, expected) in [("shown", true), ("left", false), ("right", false), ("below", false), ("transparent", false)] {
            let visible = try await view.callAsyncJavaScript("const e = document.getElementById(id); return \(AuthoredReleaseScenario.renderedVisibilitySource);", arguments: ["id": id], in: nil, contentWorld: .page)
            XCTAssertEqual(visible as? Bool, expected, id)
        }
    }
}
