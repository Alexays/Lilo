import AppKit
import UniformTypeIdentifiers
import WebKit

/// Builds a page's alert, confirm and prompt as tab-modal dialogs. Its other questions and file open requests are
/// native panels: a web view without a window (a background tab) gets their dismissed answer instead of an app-modal one.
enum JSDialogPresenter {
    /// An alert without `cancelTitle`, a confirm with it, a prompt with `field` too. With `suppress`, it offers to stop
    /// the page's further dialogs, as Chrome does from a page's second one.
    @MainActor static func pageDialog(
        in webView: WKWebView,
        frame: WKFrameInfo,
        message: String,
        field: NSTextField? = nil,
        cancelTitle: String? = nil,
        suppress: (@MainActor @Sendable () -> Void)?,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> TabModalDialogView {
        let suppressBox = suppress.map { _ in
            NSButton(checkboxWithTitle: "Prevent this page from creating additional dialogs".localized, target: nil, action: nil)
        }
        return TabModalDialogView(
            title: pageTitle(in: webView, frame: frame),
            message: message,
            accessories: [field, suppressBox].compactMap { $0 },
            acceptTitle: "OK".localized,
            cancelTitle: cancelTitle
        ) { accepted in
            if let suppress, suppressBox?.state == .on { suppress() }
            completion(accepted)
        }
    }

    /// The site that asks, as Chrome words it, so a frame cannot pass for the page it is embedded in.
    @MainActor private static func pageTitle(in webView: WKWebView, frame: WKFrameInfo) -> String {
        let page = webView.url
        let origin = frame.securityOrigin
        let isEmbedded = !frame.isMainFrame
            && (origin.protocol != page?.scheme || origin.host != page?.host() || origin.port != page?.port ?? 0)
        if let page, let host = page.host(), page.scheme == "https" || page.scheme == "http" {
            let site = page.port.map { "\(host):\($0)" } ?? host
            return String(format: (isEmbedded ? "An embedded page on %@ says" : "%@ says").localized, site)
        }
        return (isEmbedded ? "An embedded page on this page says" : "This page says").localized
    }

    /// Confirmation before leaving a page with an onbeforeunload handler. Like browsers, the page's
    /// own message is ignored (anti-abuse); only a generic prompt is shown. completion(true) = leave.
    static func runBeforeUnload(
        in webView: WKWebView,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            guard let w = webView.window else { completion(true); return }
            let alert = NSAlert()
            alert.messageText = "Leave this page?".localized
            alert.informativeText = "Changes you made may not be saved.".localized
            alert.addButton(withTitle: "Leave".localized); alert.addButton(withTitle: "Stay".localized)
            alert.beginSheetModal(for: w) { completion($0 == .alertFirstButtonReturn) }
        }
    }

    /// Confirmation before a reload or history move sends a form's data again. completion(true) = send it.
    static func runFormResubmission(
        in webView: WKWebView,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            guard let w = webView.window else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = "Confirm Form Resubmission".localized
            alert.informativeText = "This page used information you entered. Loading it again sends that information again, which may repeat an action such as a purchase.".localized
            alert.addButton(withTitle: "Continue".localized); alert.addButton(withTitle: "Cancel".localized)
            alert.beginSheetModal(for: w) { completion($0 == .alertFirstButtonReturn) }
        }
    }

    /// Storage Access API prompt: lets a cross-site embed use its own cookies under the current site.
    static func runStorageAccessPrompt(
        in webView: WKWebView,
        requestingDomain: String,
        currentDomain: String,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            guard let w = webView.window else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = String(format: "Allow \"%@\" to use cookies on \"%@\"?".localized, requestingDomain, currentDomain)
            alert.informativeText = "This lets the embedded site recognize you across sites. Only allow if you trust it.".localized
            alert.addButton(withTitle: "Allow".localized); alert.addButton(withTitle: "Don't Allow".localized)
            alert.beginSheetModal(for: w) { completion($0 == .alertFirstButtonReturn) }
        }
    }

    static func runOpenPanel(
        in webView: WKWebView,
        parameters: WKOpenPanelParameters,
        completion: @escaping @MainActor ([URL]?) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseFiles = !parameters.allowsDirectories
            panel.canChooseDirectories = parameters.allowsDirectories
            // An input's accept= is only exposed privately, as extensions; without it any file stays selectable.
            let accepted = NSSelectorFromString("_allowedFileExtensions")
            let extensions = parameters.responds(to: accepted) ? parameters.value(forKey: "_allowedFileExtensions") as? [String] : nil
            let types = (extensions ?? []).compactMap { UTType(filenameExtension: $0) }
            if !parameters.allowsDirectories, !types.isEmpty { panel.allowedContentTypes = types }
            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    completion(response == .OK ? panel.urls : nil)
                }
            } else {
                completion(panel.runModal() == .OK ? panel.urls : nil)
            }
        }
    }
}
