import Foundation
import WebKit

/// Receives the `window.close()` bridge message posted by an extension page (`liloPopupHost`) and
/// closes the one that sent it. One instance is registered per content controller; a detached
/// popup's close action sits in its window's `popupCloseHandlersByWebViewId`.
@MainActor
final class PopupCloseScriptHandler: NSObject, WKScriptMessageHandler {
    /// The controller is shared across windows, so the sender's window is looked up per message.
    weak var windows: WindowRegistry?

    init(windows: WindowRegistry) { self.windows = windows }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard message.name == "liloPopupHost" else { return }
                let command = (message.body as? [String: Any])?["command"] as? String
                guard command == "close" else { return }
                // Every extension page on the controller carries the bridge: close the page that
                // sent it, a detached popup or else its tab, never another popup.
                guard let windows, let webView = message.webView else { return }
                let webViewId = ObjectIdentifier(webView)
                if let close = windows.windows.lazy.compactMap({ $0.popupCloseHandlersByWebViewId[webViewId] }).first {
                    close()
                } else if let (owner, engine) = windows.windowAndEngine(for: webView) {
                    owner.closeTabStateFirst(id: engine.id)
                }
            }
        }
    }
}
