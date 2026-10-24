import WebKit
@testable import Lilo

extension WKWebViewTab {
    /// A tab over a bare web view, without the factory's stores and scripts, but with Lilo's feature flags.
    convenience init(id: UUID = UUID(), configuration: WKWebViewConfiguration) {
        WKFeatureFlags.apply([:], to: configuration.preferences)
        self.init(id: id, webView: WKWebView(frame: .zero, configuration: configuration))
    }
}
