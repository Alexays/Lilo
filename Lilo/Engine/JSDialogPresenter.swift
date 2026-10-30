import AppKit
import UniformTypeIdentifiers
import WebKit

/// Presents native panels for JavaScript dialogs (alert/confirm/prompt) and file open requests.
/// Stateless: depends only on the web view's window for sheet presentation. A web view without a
/// window (a background tab) gets the dismissed answer instead of an app-modal panel.
enum JSDialogPresenter {
    static func runAlert(
        in webView: WKWebView,
        message: String,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.main.async {
            guard let w = webView.window else { completion(); return }
            let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "OK".localized)
            alert.beginSheetModal(for: w) { _ in completion() }
        }
    }

    static func runConfirm(
        in webView: WKWebView,
        message: String,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            guard let w = webView.window else { completion(false); return }
            let alert = NSAlert(); alert.messageText = message
            alert.addButton(withTitle: "OK".localized); alert.addButton(withTitle: "Cancel".localized)
            alert.beginSheetModal(for: w) { completion($0 == .alertFirstButtonReturn) }
        }
    }

    static func runPrompt(
        in webView: WKWebView,
        prompt: String,
        defaultText: String?,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        DispatchQueue.main.async {
            guard let w = webView.window else { completion(nil); return }
            let alert = NSAlert(); alert.messageText = prompt
            alert.addButton(withTitle: "OK".localized); alert.addButton(withTitle: "Cancel".localized)
            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            tf.stringValue = defaultText ?? ""; alert.accessoryView = tf
            alert.beginSheetModal(for: w) { completion($0 == .alertFirstButtonReturn ? tf.stringValue : nil) }
            alert.window.makeFirstResponder(tf)
        }
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
