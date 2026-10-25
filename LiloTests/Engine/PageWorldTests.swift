import WebKit
import XCTest
@testable import Lilo

/// What a bot detector reads in a Lilo tab, against a bare WebKit page standing in for Safari's. Any difference beyond the APIs
/// Lilo adds on purpose reads as a tampered browser, which sites answer with captchas.
@MainActor
final class PageWorldTests: XCTestCase {
    /// Globals Lilo adds to WebKit's own, each a Chrome API pages use. A new one needs that reason too.
    private static let addedGlobals: Set<String> = ["EyeDropper", "Serial", "SerialPort"]
    private static let addedMembers: Set<String> = ["Navigator.prototype.serial"]

    /// Every own property of the window, its interfaces and their prototypes, and the objects Lilo's modules touch, by
    /// shape; and every function among them that does not print as native code, in its own realm or in a fresh frame's.
    private static let probe = #"""
    const fresh = document.createElement('iframe');
    document.body.appendChild(fresh);
    const freshToString = fresh.contentWindow.Function.prototype.toString;
    const fn = f => typeof f === 'function' ? f.name + '/' + f.length : typeof f;
    const describe = d => 'value' in d ? `v:${d.writable},${d.enumerable},${d.configurable}:${fn(d.value)}`
      : `a:${d.enumerable},${d.configurable}:${d.get ? fn(d.get) : ''}:${d.set ? fn(d.set) : ''}`;
    const shapes = {}, nonNative = [];
    const native = (f, path) => {
      for (const toString of [Function.prototype.toString, freshToString]) {
        let text;
        try { text = toString.call(f); } catch (e) { text = 'throws'; }
        if (!/^function [^(]*\(\) \{\n    \[native code\]\n\}$/.test(text)) return void nonNative.push(path);
      }
    };
    const visit = (object, path) => {
      for (const key of Reflect.ownKeys(object)) {
        const name = path + '.' + String(key);
        const d = Object.getOwnPropertyDescriptor(object, key);
        shapes[name] = describe(d);
        for (const f of [d.value, d.get, d.set]) if (typeof f === 'function') native(f, name);
      }
    };
    visit(window, 'window');
    for (const key of Object.getOwnPropertyNames(window)) {
      let value;
      try { value = window[key]; } catch (e) { continue; }
      if (typeof value === 'function' && value.prototype) { visit(value, key); visit(value.prototype, key + '.prototype'); }
    }
    for (const [path, object] of [['navigator', navigator], ['document', document], ['mediaDevices', navigator.mediaDevices],
                                  ['geolocation', navigator.geolocation], ['mediaSession', navigator.mediaSession]]) {
      if (object) visit(object, path);
    }
    const frame = fresh.contentWindow;
    for (const key of ['Notification', 'EyeDropper', 'Serial']) if (frame[key]) native(frame[key], 'frame.' + key);
    native(frame.Geolocation.prototype.getCurrentPosition, 'frame.Geolocation.prototype.getCurrentPosition');
    shapes['webkit in window'] = String('webkit' in window);
    shapes['webkit in frame'] = String('webkit' in frame);
    shapes['frame keys'] = Object.keys(frame).join();
    return JSON.stringify({ shapes, nonNative, userAgent: navigator.userAgent, vendor: navigator.vendor,
                            userAgentData: 'userAgentData' in navigator });
    """#

    private struct Report: Decodable {
        let shapes: [String: String]
        let nonNative: [String]
        let userAgent: String
        let vendor: String
        let userAgentData: Bool
    }

    private func report(of webView: WKWebView) async throws -> Report {
        webView.loadHTMLString("<p>probe</p>", baseURL: URL(string: "https://example.com/"))
        let loaded = await pollUntil(timeout: 10) {
            let condition = "location.href === 'https://example.com/' && document.readyState === 'complete'"
            return ((try? await webView.evaluateJavaScript(condition)) as? Bool) == true
        }
        XCTAssertTrue(loaded)
        let result = try await webView.callAsyncJavaScript(Self.probe, contentWorld: .page)
        let json = try XCTUnwrap(result as? String)
        return try JSONDecoder().decode(Report.self, from: Data(json.utf8))
    }

    func testATabShowsPagesNothingABareWebKitPageDoesNot() async throws {
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        defer { tab.teardown() }
        let lilo = try await report(of: tab.wkWebView)

        // The same engine settings without Lilo's scripts and handlers: only WebKit's own native APIs, as in Safari.
        let configuration = try XCTUnwrap(tab.wkWebView.configuration.copy() as? WKWebViewConfiguration)
        configuration.userContentController = WKUserContentController()
        let bare = try await report(of: WKWebView(frame: .zero, configuration: configuration))

        func isAdded(_ path: String) -> Bool {
            let root = path.hasPrefix("window.") ? String(path.dropFirst(7)) : String(path.prefix { $0 != "." })
            return Self.addedGlobals.contains(root) || Self.addedMembers.contains(path)
        }
        let added = Set(lilo.shapes.keys).subtracting(bare.shapes.keys)
        XCTAssertEqual(added.filter { !isAdded($0) }.sorted(), [], "properties a Safari page does not have")
        XCTAssertEqual(Set(bare.shapes.keys).subtracting(lilo.shapes.keys).sorted(), [], "properties a Safari page has")
        let changed = bare.shapes.compactMap { key, shape in lilo.shapes[key].flatMap { $0 == shape ? nil : "\(key): \(shape) -> \($0)" } }
        XCTAssertEqual(changed.sorted(), [], "properties shaped unlike Safari's")
        XCTAssertEqual(lilo.nonNative, [], "functions that print their source")
        for global in Self.addedGlobals {
            XCTAssertEqual(lilo.shapes["window.\(global)"], "v:true,false,true:\(global)/0", "\(global) is defined as an interface object is")
        }
        XCTAssertEqual(lilo.shapes["webkit in window"], "false")

        XCTAssertEqual(lilo.userAgent, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                       + WKEngineFactory.safariApplicationName)
        XCTAssertEqual(lilo.vendor, "Apple Computer, Inc.")
        XCTAssertFalse(lilo.userAgentData)
    }
}
