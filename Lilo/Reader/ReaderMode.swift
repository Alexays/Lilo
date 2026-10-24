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

    @MainActor
    static func apply(to webView: WKWebView) {
        guard !script.isEmpty else { return }
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
    }
}
