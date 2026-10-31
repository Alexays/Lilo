import WebKit

/// In-page reader mode: parses the main article with the bundled Mozilla Readability.js (Apache-2.0)
/// and renders it via `ReaderView.js` into a clean, themable reading surface with text-size / theme /
/// width controls. Exiting is a normal reload, handled by the caller (MainWindowController).
enum ReaderMode {
    /// Readability engine + render harness, concatenated once from the bundle. The leading `;` guards
    /// against ASI joining the two files; ReaderView self-aborts if `Readability` failed to load.
    private static let script: String = {
        ["Readability", "ReaderView"]
            .compactMap { name in
                Bundle.appResourceURL(name, extension: "js")
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }
            .joined(separator: "\n;\n")
    }()

    /// Readability and the controls' listener live in their own world: the page sees neither.
    @MainActor static let world = WKContentWorld.world(name: "lilo-reader")

    /// The text size, theme and width the controls last picked, the same on every site.
    private static let preferencesKey = "ReaderPreferences"

    /// `completion` gets whether the page now shows the article: false for a page that is not one.
    @MainActor
    static func apply(to webView: WKWebView, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard !script.isEmpty else { return completion(false) }
        let controller = webView.configuration.userContentController
        // Tabs can share a content controller, which takes one handler per name.
        controller.removeScriptMessageHandler(forName: PreferencesHandler.name, contentWorld: world)
        controller.add(PreferencesHandler.shared, contentWorld: world, name: PreferencesHandler.name)
        let preferences = UserDefaults.standard.dictionary(forKey: preferencesKey) ?? [:]
        let json = (try? JSONSerialization.data(withJSONObject: preferences)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        webView.evaluateJavaScript("var liloReaderPrefs = \(json);\n" + script, in: nil, in: world) { completion((try? $0.get()) as? Bool == true) }
    }

    @MainActor
    private final class PreferencesHandler: NSObject, WKScriptMessageHandler {
        static let name = "liloReaderPrefs"
        static let shared = PreferencesHandler()

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            var preferences: [String: Any] = [:]
            preferences["fontSize"] = body["fontSize"] as? Int
            preferences["theme"] = body["theme"] as? String
            preferences["width"] = body["width"] as? String
            UserDefaults.standard.set(preferences, forKey: ReaderMode.preferencesKey)
        }
    }
}
