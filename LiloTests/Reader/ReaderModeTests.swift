import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ReaderModeTests: XCTestCase {
    private static let article = "<article><h1>A long story</h1>" + String(repeating: "<p>\(String(repeating: "Words worth reading in reader mode. ", count: 12))</p>", count: 6) + "</article>"

    private func openInReader(_ host: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(Self.article, baseURL: URL(string: "https://\(host)/"))
        let loaded = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript("location.host === '\(host)' && document.readyState === 'complete'")) as? Bool == true }
        XCTAssertTrue(loaded)
        ReaderMode.apply(to: webView)
        let shown = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript("!!document.querySelector('#lilo-reader-bar')")) as? Bool == true }
        XCTAssertTrue(shown)
        return webView
    }

    func testReaderSettingsStayOutOfThePageAndFollowEverySite() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "ReaderPreferences")
        defaults.removeObject(forKey: "ReaderPreferences")
        addTeardownBlock { @MainActor in defaults.set(saved, forKey: "ReaderPreferences") }

        let first = try await openInReader("one.example")
        _ = try await first.evaluateJavaScript("document.querySelector('[data-act=inc]').click(); 0")
        let stored = await pollUntil(timeout: 5) { (defaults.dictionary(forKey: "ReaderPreferences")?["fontSize"] as? Int) == 20 }
        XCTAssertTrue(stored)
        let pageStorage = try await first.evaluateJavaScript("localStorage.length") as? Int
        XCTAssertEqual(pageStorage, 0, "the page can read its own storage: reader settings never land there")
        let pageHandlers = try await first.evaluateJavaScript("typeof webkit") as? String
        XCTAssertEqual(pageHandlers, "undefined", "the settings go back through the reader's world, which the page cannot see")

        let second = try await openInReader("two.example")
        let font = try await second.evaluateJavaScript("document.documentElement.style.getPropertyValue('--lilo-reader-font')") as? String
        XCTAssertEqual(font, "20px", "a text size picked on one site applies on every site")
    }
}
