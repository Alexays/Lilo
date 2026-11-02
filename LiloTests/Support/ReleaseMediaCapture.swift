import AppKit
import CryptoKit
import ScreenCaptureKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ReleaseMediaCapture {
    let fixture: TemporaryBrowserContext
    let controller: MainWindowController
    let space: Space
    let output: URL
    let version: String
    let feature: String
    private let backdrop: NSWindow
    private let cachedLayout = (position: UserDefaults.lilo.string(forKey: "cachedTabPosition"),
                                address: UserDefaults.lilo.string(forKey: "cachedAddressPlacement"))
    private var assets: [[String: Any]] = []
    var context: BrowserContext { fixture.context }
    var chrome: WKWebView { controller.chromeWebView }

    init(version: String, feature: String) async throws {
        let env = ProcessInfo.processInfo.environment
        let requested = env["LILO_RELEASE_MEDIA_VERSION", default: ""]
        let fixtureVersion = env["LILO_RELEASE_MEDIA_FIXTURE_VERSION"] ?? requested
        guard let directory = env["LILO_RELEASE_MEDIA_OUT"],
              fixtureVersion.isEmpty || fixtureVersion == version || "\(fixtureVersion)-announcement" == version else {
            throw XCTSkip("Opt-in native release media capture")
        }
        let addressCapture = version == "0.8.0-announcement"
        self.version = requested.isEmpty ? (addressCapture ? "0.8.0" : version) : requested
        self.feature = feature
        let releaseOutput = URL(fileURLWithPath: directory).appendingPathComponent(self.version)
        output = addressCapture ? releaseOutput.appendingPathComponent("address-bar") : releaseOutput
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output.appendingPathComponent("capture.json"))
        try? FileManager.default.removeItem(at: output.appendingPathComponent("failure.json"))
        fixture = try await TemporaryBrowserContext()
        let context = fixture.context
        let settingsStore = try XCTUnwrap(context.settingsStore)
        settingsStore.set("onboardingCompleted", value: "true")
        settingsStore.set("theme", value: "dark")
        settingsStore.set("tabPosition", value: "left")
        settingsStore.set("addressPlacement", value: "tabs")
        settingsStore.didPromptDefaultBrowser = true
        let profile = try XCTUnwrap(context.profileManager).createProfile(name: "Studio")
        space = try XCTUnwrap(context.spaceManager).createSpace(name: "Research", icon: "🌿", color: "#8b79c6", profileId: profile.id)
        controller = MainWindowController(context: context)
        context.windows.add(controller)
        controller.restoreWindowChromeState()
        controller.setupBridgeEarly()
        controller.setupViews()
        controller.setupBridgeLate()
        controller.setupTabShare()
        controller.applyTabLayout(settingsStore.tabLayout, animated: false)
        controller.switchToSpace(space.id)
        controller.didCompleteSessionRestore = true
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1280, height: 800))
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.midY - window.frame.height / 2))
        }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -60, dy: -60), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        backdrop.contentView = CaptureBackdrop(frame: NSRect(origin: .zero, size: backdrop.frame.size))
        window.addChildWindow(backdrop, ordered: .below)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        controller.loadChromeUI()
        do {
            try await wait("native chrome is ready", timeout: 30) { self.controller.didChromeVisualReady }
            // The picker normally reads the person's wallpaper. Only its fixture input is substituted.
            let thumbnail = try CaptureBackdrop.png(size: NSSize(width: 480, height: 300)).base64EncodedString()
            _ = try await chrome.callAsyncJavaScript("""
                const rewrite = m => m.event === 'wallpaperColorChanged' ? {...m, thumbnail: 'data:image/png;base64,' + thumbnail, color:'#8b79c6'} : m;
                const receive=window.__lilo.receive.bind(window.__lilo), batch=window.__lilo.receiveBatch.bind(window.__lilo);
                window.__lilo.receive=m=>receive(rewrite(m));
                window.__lilo.receiveBatch=ms=>batch(ms.map(rewrite));
                """, arguments: ["thumbnail": thumbnail], in: nil, contentWorld: .page)
        } catch {
            close()
            throw error
        }
    }

    func close() {
        fixture.tearDown()
        backdrop.close()
        UserDefaults.lilo.set(cachedLayout.position, forKey: "cachedTabPosition")
        UserDefaults.lilo.set(cachedLayout.address, forKey: "cachedAddressPlacement")
    }

    @discardableResult
    func page(title: String = "Field notes", color: String = "#38334f") async throws -> Tab {
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "about:blank")))
        try await loadPage(in: tab, title: title, color: color)
        return tab
    }

    func loadPage(in tab: Tab, title: String, color: String = "#38334f", url: URL = URL(string: "https://example.com/notes/")!) async throws {
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        engine.wkWebView.stopLoading()
        engine.wkWebView.loadHTMLString("""
            <!doctype html><html><meta charset="utf-8"><title>\(title)</title><meta name="theme-color" content="\(color)">
            <style>*{box-sizing:border-box}html{background:#17171c;color:#ecebf3;font:18px/1.6 -apple-system,sans-serif}body{margin:0}header{background:\(color);padding:50px 10% 44px}small{font-size:12px;letter-spacing:.12em;color:#c0bcd3}h1{font-size:44px;letter-spacing:-.04em;line-height:1.15;margin:14px 0}main{padding:40px 10%;max-width:1000px}h2{font-size:26px;font-weight:500;margin:0 0 16px}p{color:#b2afbf}article{border-top:1px solid #37343f;padding:25px 0}a{color:#c2b6f1}</style>
            <header><small>STUDIO / RESEARCH</small><h1>\(title)</h1><p>A little more room for what comes next.</p></header>
            <main><h2>Keep one idea in view.</h2><p>Collect the useful details. Leave room to explore.</p><article><h2>A clear starting point</h2><p>Notes, references and a place to begin.</p><a href="https://example.com/guide">Open the field guide</a></article><article><h2>The next chapter</h2><p>Bring the work together, one step at a time.</p></article></main></html>
            """, baseURL: url)
        try await wait("synthetic content loads") {
            (try? await engine.wkWebView.evaluateJavaScript("document.title")) as? String == title
        }
        try await wait("native tab title matches the owned page") { self.controller.tabManager.tab(for: tab.id)?.title == title }
    }

    func wait(_ message: String, timeout: TimeInterval = 12, _ condition: @MainActor () async -> Bool) async throws {
        let passed = await pollUntil(timeout: timeout, condition)
        XCTAssertTrue(passed, message)
        if !passed {
            let detail = try? await chrome.evaluateJavaScript("(()=>{const v=document.querySelector('.whats-new video'),q=v?.getVideoPlaybackQuality();return {url:location.href,visibility:document.visibilityState,ready:document.readyState,width:innerWidth,height:innerHeight,booting:document.documentElement.hasAttribute('data-booting'),text:document.body.innerText.slice(0,500),video:v?{time:v.currentTime,duration:v.duration,frames:q.totalVideoFrames,dropped:q.droppedVideoFrames,paused:v.paused,ready:v.readyState}:null}})()")
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let record: [String: Any] = ["message": message, "chrome": detail ?? [:], "windowVisible": controller.window?.isVisible ?? false,
                                         "windowUnoccluded": controller.window?.occlusionState.contains(.visible) ?? false,
                                         "windowOnActiveSpace": controller.window?.isOnActiveSpace ?? false,
                                         "windowIsKey": controller.window?.isKeyWindow ?? false,
                                         "appActive": NSApp.isActive,
                                         "sessionLocked": session?["CGSSessionScreenIsLocked"] as? Bool ?? false]
            try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("failure.json"))
            throw NSError(domain: "ReleaseMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func click(_ selector: String, text: String? = nil) async throws {
        let clicked = try await chrome.callAsyncJavaScript("""
            const el = [...document.querySelectorAll(selector)].find(e => text === null || e.textContent.trim() === text);
            if (!el || el.disabled) return false; el.click(); return true;
            """, arguments: ["selector": selector, "text": text as Any? ?? NSNull()], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(clicked, true, "Actual production control must exist: \(selector) \(text ?? "")")
        if clicked != true { throw NSError(domain: "ReleaseMedia", code: 2) }
    }

    func exists(_ selector: String) async -> Bool {
        (try? await chrome.callAsyncJavaScript("return !!document.querySelector(selector)", arguments: ["selector": selector], in: nil, contentWorld: .page)) as? Bool == true
    }

    func input(_ selector: String, value: String) async throws {
        _ = try await chrome.callAsyncJavaScript("""
            const input=document.querySelector(selector);
            if (!input) throw Error('Missing native input: '+selector);
            input.focus(); input.value=value; input.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:value}));
            """, arguments: ["selector": selector, "value": value], in: nil, contentWorld: .page)
    }

    func callPage() async throws -> Tab {
        let tab = try await page(title: "Studio call")
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        _ = try await engine.wkWebView.callAsyncJavaScript("""
            window.fixtureMic=true;window.fixtureCamera=true;
            navigator.mediaSession.setActionHandler('togglemicrophone',()=>navigator.mediaSession.setMicrophoneActive(window.fixtureMic=!window.fixtureMic));
            navigator.mediaSession.setActionHandler('togglecamera',()=>navigator.mediaSession.setCameraActive(window.fixtureCamera=!window.fixtureCamera));
            navigator.mediaSession.setActionHandler('hangup',()=>{window.fixtureHungUp=true});
            await navigator.mediaSession.setMicrophoneActive(true);await navigator.mediaSession.setCameraActive(true);
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        // Device usage is fixture input; the real Media Session handlers and native call controls run unchanged.
        context.browserState.updateTab(id: tab.id) { $0.isMicrophoneActive = true; $0.isCameraActive = true }
        context.mediaActivityChanged()
        try await wait("real Media Session registers a native call") { self.context.callTabIds.contains(tab.id) }
        return tab
    }

    func settled(in webView: WKWebView? = nil) async throws {
        _ = try await (webView ?? chrome).callAsyncJavaScript("""
            await document.fonts.ready;
            await Promise.all([...document.images].map(i=>i.decode().catch(()=>{})));
            await Promise.all(document.getAnimations().filter(a=>a.effect?.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{})));
            await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
            """, arguments: [:], in: nil, contentWorld: .page)
    }

    func region(_ selector: String, name: String, scale: CGFloat = 8, margin: CGFloat = 14, in webView: WKWebView? = nil, crop: CGSize? = nil) async throws {
        let view = webView ?? chrome
        try await settled(in: view)
        let raw = try await view.callAsyncJavaScript("""
            const rs=[...document.querySelectorAll(selector)].map(e=>e.getBoundingClientRect()).filter(r=>r.width&&r.height);
            if(!rs.length) throw Error('Missing visible native capture region: '+selector);
            const x=Math.min(...rs.map(r=>r.x)), y=Math.min(...rs.map(r=>r.y));
            return [x,y,Math.max(...rs.map(r=>r.right))-x,Math.max(...rs.map(r=>r.bottom))-y];
            """, arguments: ["selector": selector], in: nil, contentWorld: .page)
        let r = try XCTUnwrap(raw as? [Double])
        var rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).insetBy(dx: -margin, dy: -margin).intersection(view.bounds).integral
        if let crop { rect.size = CGSize(width: min(rect.width, crop.width), height: min(rect.height, crop.height)) }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: rect.width * scale / (view.window?.backingScaleFactor ?? 1))
        let image = try await view.takeSnapshot(configuration: config)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(bitmap.pixelsWide, Int(rect.width * scale))
        try save(bitmap, name: name, tool: "WKWebView.takeSnapshot", points: rect, scale: scale)
    }

    func window(_ name: String) async throws {
        try await settled()
        try await wait("native window layout has settled") {
            self.controller.contentContainerView.layer?.animation(forKey: "sidebarSlide") == nil
        }
        let nativeWindow = try XCTUnwrap(controller.window)
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(nativeWindow.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        XCTAssertGreaterThanOrEqual(filter.pointPixelScale, 2)
        XCTAssertEqual(image.width, config.width)
        try save(NSBitmapImageRep(cgImage: image), name: name, tool: "ScreenCaptureKit desktop-independent native window", points: filter.contentRect, scale: CGFloat(filter.pointPixelScale))
    }

    func finish(checks: [String: Any]) throws {
        let env = ProcessInfo.processInfo.environment
        let receipt: [String: Any] = [
            "schemaVersion": 1, "release": version, "feature": feature,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
            "productSourceCommit": env["LILO_RELEASE_MEDIA_COMMIT"] ?? "",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "fixture": "Disposable profile, synthetic example.com content and owned gradient backdrop; no personal data",
            "checks": checks, "assets": assets,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("capture.json"), options: .atomic)
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String, tool: String, points: CGRect, scale: CGFloat) throws {
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let file = "\(name).png"
        try data.write(to: output.appendingPathComponent(file), options: .atomic)
        assets.append(["file": file, "tool": tool, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
                       "rectPoints": [points.minX, points.minY, points.width, points.height], "pixelsPerPoint": scale,
                       "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
    }
}

private final class CaptureBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(cssHex: "#607ea8")!, NSColor(cssHex: "#b8a1c4")!, NSColor(cssHex: "#c6a686")!])!.draw(in: bounds, angle: 25)
    }

    static func png(size: NSSize) throws -> Data {
        let view = CaptureBackdrop(frame: NSRect(origin: .zero, size: size))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
