import AppKit
import ScreenCaptureKit
import WebKit
import XCTest
@testable import Lilo

/// One step of a release media plan, the JSON `make changelog-draft` writes under `release-media/plans/`.
struct ReleaseMediaStep: Decodable {
    let `do`: String
    var selector: String?
    var text: String?
    var value: String?
    var name: String?
}

struct ReleaseMediaPlan: Decodable {
    let steps: [ReleaseMediaStep]
}

/// Drives the compiled app with a disposable profile and owned example.com pages, and saves what it shows.
@MainActor
final class ReleaseMediaCapture {
    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private struct Shot {
        let file: String
        let width: Int
        let height: Int
        let rect: CGRect
        var click: [Double]?
    }

    private let fixture: TemporaryBrowserContext
    private let controller: MainWindowController
    private let output: URL
    private let backdrop: NSWindow
    private let cachedLayout = (position: UserDefaults.lilo.string(forKey: "cachedTabPosition"),
                                address: UserDefaults.lilo.string(forKey: "cachedAddressPlacement"))
    private var shots: [Shot] = []
    private var context: BrowserContext { fixture.context }
    private var chrome: WKWebView { controller.chromeWebView }

    init(output: URL) async throws {
        self.output = output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        fixture = try await TemporaryBrowserContext()
        let context = fixture.context
        let settingsStore = try XCTUnwrap(context.settingsStore)
        settingsStore.set("onboardingCompleted", value: "true")
        settingsStore.set("theme", value: "dark")
        settingsStore.set("tabPosition", value: "left")
        settingsStore.set("addressPlacement", value: "tabs")
        settingsStore.didPromptDefaultBrowser = true
        let profile = try XCTUnwrap(context.profileManager).createProfile(name: "Studio")
        let space = try XCTUnwrap(context.spaceManager).createSpace(name: "Research", icon: "🌿", color: "#8b79c6", profileId: profile.id)
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
            try await wait("the chrome to be ready", timeout: 30) { self.controller.didChromeVisualReady }
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

    func run(_ step: ReleaseMediaStep) async throws {
        let selector = step.selector ?? ""
        switch step.do {
        case "page": try await page(title: step.text ?? "Field notes")
        case "call": try await call()
        case "action": try perform(step.name ?? "")
        case "click": try await click(selector, text: step.text)
        case "input": try await input(selector, value: step.value ?? "")
        case "wait": try await wait(selector) { await self.exists(selector) }
        case "shot":
            if let selector = step.selector { try await region(selector) } else { try await window() }
        default: throw Failure(errorDescription: "Unknown step: \(step.do)")
        }
    }

    /// The manifest the renderer reads: each shot, and where its next click lands as a fraction of it.
    func finish() throws {
        let manifest = shots.map { shot -> [String: Any] in
            var entry: [String: Any] = ["file": shot.file, "width": shot.width, "height": shot.height]
            entry["click"] = shot.click
            return entry
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("shots.json"), options: .atomic)
    }

    private func perform(_ action: String) throws {
        switch action {
        case "openSettings": controller.openSettings(nil)
        case "openHistory": controller.openHistory(nil)
        case "editCurrentSpace": controller.editCurrentSpace(nil)
        case "pinCurrentTab": controller.pinCurrentTab(nil)
        case "newTab": controller.newTab(nil)
        case "toggleSidebar": controller.toggleSidebar()
        default: throw Failure(errorDescription: "Unknown action: \(action)")
        }
    }

    @discardableResult
    private func page(title: String) async throws -> Tab {
        let color = "#38334f"
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: URL(string: "about:blank")))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        engine.wkWebView.stopLoading()
        engine.wkWebView.loadHTMLString("""
            <!doctype html><html><meta charset="utf-8"><title>\(title)</title><meta name="theme-color" content="\(color)">
            <style>*{box-sizing:border-box}html{background:#17171c;color:#ecebf3;font:18px/1.6 -apple-system,sans-serif}body{margin:0}header{background:\(color);padding:56px 72px}h1{margin:8px 0;font-size:44px}main{padding:36px 72px}</style>
            <header><small>STUDIO / RESEARCH</small><h1>\(title)</h1><p>A little more room for what comes next.</p></header>
            <main><h2>Keep one idea in view.</h2><p>Collect the useful details. Leave room to explore.</p><h2>A clear starting point</h2><p>Notes, references and a place to begin.</p></main>
            """, baseURL: URL(string: "https://example.com/notes/"))
        try await wait("the page title") { self.controller.tabManager.tab(for: tab.id)?.title == title }
        return tab
    }

    private func call() async throws {
        let tab = try await page(title: "Studio call")
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        _ = try await engine.wkWebView.callAsyncJavaScript("""
            navigator.mediaSession.setActionHandler('togglemicrophone',()=>{});
            navigator.mediaSession.setActionHandler('togglecamera',()=>{});
            navigator.mediaSession.setActionHandler('hangup',()=>{});
            await navigator.mediaSession.setMicrophoneActive(true);await navigator.mediaSession.setCameraActive(true);
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        context.browserState.updateTab(id: tab.id) { $0.isMicrophoneActive = true; $0.isCameraActive = true }
        context.mediaActivityChanged()
        try await wait("a call") { self.context.callTabIds.contains(tab.id) }
    }

    private func wait(_ what: String, timeout: TimeInterval = 12, _ condition: @MainActor () async -> Bool) async throws {
        guard await pollUntil(timeout: timeout, condition) else { throw Failure(errorDescription: "Timed out waiting for \(what)") }
    }

    private func exists(_ selector: String) async -> Bool {
        (try? await chrome.callAsyncJavaScript("return !!document.querySelector(selector)", arguments: ["selector": selector], in: nil, contentWorld: .page)) as? Bool == true
    }

    private func click(_ selector: String, text: String?) async throws {
        let center = try await chrome.callAsyncJavaScript("""
            const el = [...document.querySelectorAll(selector)].find(e => text === null || e.textContent.trim() === text);
            if (!el || el.disabled) return null;
            const r = el.getBoundingClientRect(); el.click();
            return [r.x + r.width / 2, r.y + r.height / 2];
            """, arguments: ["selector": selector, "text": text as Any? ?? NSNull()], in: nil, contentWorld: .page) as? [Double]
        guard let center else { throw Failure(errorDescription: "No control to click: \(selector) \(text ?? "")") }
        if let rect = shots.last?.rect, rect.contains(CGPoint(x: center[0], y: center[1])) {
            shots[shots.count - 1].click = [(center[0] - rect.minX) / rect.width, (center[1] - rect.minY) / rect.height]
        }
    }

    private func input(_ selector: String, value: String) async throws {
        _ = try await chrome.callAsyncJavaScript("""
            const input = document.querySelector(selector);
            if (!input) throw Error('No field: ' + selector);
            input.focus(); input.value = value; input.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: value}));
            """, arguments: ["selector": selector, "value": value], in: nil, contentWorld: .page)
    }

    private func settled() async throws {
        _ = try await chrome.callAsyncJavaScript("""
            await document.fonts.ready;
            await Promise.all([...document.images].map(i => i.decode().catch(() => {})));
            await Promise.all(document.getAnimations().filter(a => a.effect?.getTiming().iterations !== Infinity).map(a => a.finished.catch(() => {})));
            await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
            """, arguments: [:], in: nil, contentWorld: .page)
    }

    /// A close-up rendered at four pixels per point, sharp at any size the film shows it.
    private func region(_ selector: String) async throws {
        try await settled()
        let raw = try await chrome.callAsyncJavaScript("""
            const rects = [...document.querySelectorAll(selector)].map(e => e.getBoundingClientRect()).filter(r => r.width && r.height);
            if (!rects.length) return null;
            const x = Math.min(...rects.map(r => r.x)), y = Math.min(...rects.map(r => r.y));
            return [x, y, Math.max(...rects.map(r => r.right)) - x, Math.max(...rects.map(r => r.bottom)) - y];
            """, arguments: ["selector": selector], in: nil, contentWorld: .page) as? [Double]
        guard let raw else { throw Failure(errorDescription: "Nothing visible to capture: \(selector)") }
        let scale: CGFloat = 4
        let rect = CGRect(x: raw[0], y: raw[1], width: raw[2], height: raw[3]).intersection(chrome.bounds).integral
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: rect.width * scale / (chrome.window?.backingScaleFactor ?? 1))
        let image = try await chrome.takeSnapshot(configuration: config)
        try save(XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))), rect: rect)
    }

    private func window() async throws {
        try await settled()
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
        try save(NSBitmapImageRep(cgImage: image), rect: chrome.bounds)
    }

    private func save(_ bitmap: NSBitmapImageRep, rect: CGRect) throws {
        let file = "shot-\(shots.count).png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(file), options: .atomic)
        shots.append(Shot(file: file, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, rect: rect))
    }
}

private final class CaptureBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(cssHex: "#607ea8")!, NSColor(cssHex: "#b8a1c4")!, NSColor(cssHex: "#c6a686")!])!.draw(in: bounds, angle: 25)
    }
}
