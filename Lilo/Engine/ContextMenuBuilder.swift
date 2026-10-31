import AppKit
import WebKit
import os

/// Schemes `WKDownload` can actually fetch. Restricts both the "no native item matched" fallback
/// and native-item retargeting below. Without it, right-clicking a `mailto:`/`tel:`/`javascript:`
/// link (for which WebKit deliberately shows no download item) would grow one anyway.
private let downloadableSchemes: Set<String> = ["http", "https", "blob", "data", "file"]

private func isDownloadable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return downloadableSchemes.contains(scheme)
}

/// Builds a tab's context menu from WebKit's: Lilo's tab, window and space actions replace "Open Link in New Window", plus
/// extension and nav/copy/PiP items. It is the items' `@objc` target, hence `NSObject`; the tab injects the behavior.
@MainActor
final class ContextMenuBuilder: NSObject {
    private static let logger = Logger(liloCategory: "context-menu")

    private let webView: WKWebView
    private let onOpenInNewTab: (URL) -> Void
    private let onOpenInPrivateSpace: (URL) -> Void
    private let onOpenInNewWindow: (URL) -> Void
    private let onTogglePiP: () -> Void
    private let onBookmark: () -> Void
    private let onDownload: (URL) -> Void
    private let onSearchWeb: () -> Void

    init(
        webView: WKWebView,
        onOpenInNewTab: @escaping (URL) -> Void,
        onOpenInPrivateSpace: @escaping (URL) -> Void,
        onOpenInNewWindow: @escaping (URL) -> Void,
        onTogglePiP: @escaping () -> Void,
        onBookmark: @escaping () -> Void,
        onDownload: @escaping (URL) -> Void,
        onSearchWeb: @escaping () -> Void
    ) {
        self.webView = webView
        self.onOpenInNewTab = onOpenInNewTab
        self.onOpenInPrivateSpace = onOpenInPrivateSpace
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onTogglePiP = onTogglePiP
        self.onBookmark = onBookmark
        self.onDownload = onDownload
        self.onSearchWeb = onSearchWeb
        super.init()
    }

    /// `_WKContextMenuElementInfo.hitTestResult.absoluteLinkURL`, read by KVC (private classes).
    static func linkURL(from element: NSObject?) -> URL? { hitTestValue("absoluteLinkURL", from: element) }

    /// `_WKContextMenuElementInfo.hitTestResult.absoluteImageURL`, read by KVC (private classes).
    static func imageURL(from element: NSObject?) -> URL? { hitTestValue("absoluteImageURL", from: element) }

    /// `_WKContextMenuElementInfo.hitTestResult.absoluteMediaURL` (video/audio), read by KVC.
    static func mediaURL(from element: NSObject?) -> URL? { hitTestValue("absoluteMediaURL", from: element) }

    /// `_WKContextMenuElementInfo.hitTestResult.frameInfo`, the frame holding the clicked element, read by KVC.
    static func frameInfo(from element: NSObject?) -> WKFrameInfo? { hitTestValue("frameInfo", from: element) }

    /// nil when WebKit renames either private property, instead of raising on the KVC read.
    private static func hitTestValue<Value>(_ key: String, from element: NSObject?) -> Value? {
        guard let element, element.responds(to: NSSelectorFromString("hitTestResult")),
              let result = element.value(forKey: "hitTestResult") as? NSObject,
              result.responds(to: NSSelectorFromString(key)) else { return nil }
        return result.value(forKey: key) as? Value
    }

    /// `element` is the clicked `_WKContextMenuElementInfo`, whose hit test tells a text field or the selection.
    func build(
        _ menu: NSMenu, linkURL: URL?, imageURL: URL? = nil, element: NSObject? = nil, extensionItems: [NSMenuItem],
        offersNewWindow: Bool = true, searchEngineName: String? = nil
    ) {
        // WebKit's "Search with Google" hands the selection to the system's search service, which opens the default browser.
        if let searchEngineName, let item = menu.items.first(where: { $0.identifier?.rawValue.localizedCaseInsensitiveContains("SearchWeb") ?? false }) {
            item.title = String(format: "Search with %@".localized, searchEngineName)
            item.target = self
            item.action = #selector(contextMenuSearchWeb)
        }

        // WebKit's native "Download Image"/"Download Linked File" items never fire WKDownloadDelegate,
        // so route them through Lilo's download pipeline (via `onDownload`).
        wireDownloadItems(in: menu, imageURL: imageURL, linkURL: linkURL)

        // Read by KVC (private class), false when WebKit renames a property.
        let hitTest = element.flatMap { $0.responds(to: NSSelectorFromString("hitTestResult")) ? $0.value(forKey: "hitTestResult") as? NSObject : nil }
        let isTextTarget = ["isContentEditable", "isSelected"].contains { getter in
            hitTest?.responds(to: NSSelectorFromString(getter)) == true && hitTest?.value(forKey: getter) as? Bool == true
        }

        if let linkURL {
            // WebKit's own "Open Link in New Window" opens a popup-style window; Lilo's items open a
            // browser tab, window or private space instead.
            var linkItems = [
                makeLinkItem("Open Link in New Tab", icon: .openInNewTab, action: #selector(contextMenuOpenLinkInNewTab(_:)), url: linkURL),
                makeLinkItem("Open Link in New Private Space", icon: .newPrivateSpace, action: #selector(contextMenuOpenLinkInNewPrivateSpace(_:)), url: linkURL)
            ]
            if offersNewWindow {
                linkItems.insert(makeLinkItem("Open Link in New Window", icon: .newWindow, action: #selector(contextMenuOpenLinkInNewWindow(_:)), url: linkURL), at: 1)
            }
            if let windowIndex = menu.items.firstIndex(where: { Self.isOpenInNewWindowItem($0) }) {
                menu.removeItem(at: windowIndex)
                for (offset, item) in linkItems.enumerated() { menu.insertItem(item, at: windowIndex + offset) }
            } else {
                // WebKit didn't expose the New Window item under a known identifier; still offer ours.
                menu.addItem(.separator())
                linkItems.forEach(menu.addItem)
                #if DEBUG
                Self.logger.debug("ctx-menu link items: no New Window match: identifiers=\(menu.items.map { $0.identifier?.rawValue ?? "·" }.joined(separator: ","), privacy: .public)")
                #endif
            }
        }

        // Extension context menu items (chrome.contextMenus)
        if !extensionItems.isEmpty {
            // WebKit already proposes its own copies; Lilo's replace them, as choosing one counts as the
            // extension's user gesture.
            for item in menu.items where (item.target as? NSObject)?.className == "_WKWebExtensionMenuItem" {
                menu.removeItem(item)
            }
            menu.addItem(.separator())
            extensionItems.forEach { menu.addItem($0) }
        }

        // As Chrome, the page's own items stay out of a link, media, selection or text field menu: a stray Back loses typed text.
        guard linkURL == nil, imageURL == nil, !isTextTarget else { return menu.showItemImages() }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Back", icon: .back, action: #selector(contextMenuBack), isEnabled: webView.canGoBack))
        menu.addItem(makeMenuItem("Forward", icon: .forward, action: #selector(contextMenuForward), isEnabled: webView.canGoForward))
        menu.addItem(makeMenuItem("Reload", icon: .reload, action: #selector(contextMenuReload)))

        if let url = webView.url {
            menu.addItem(.separator())
            let copyItem = makeMenuItem("Copy Page URL", icon: .copyLink, action: #selector(contextMenuCopyURL(_:)))
            copyItem.representedObject = url
            menu.addItem(copyItem)
            menu.addItem(makeMenuItem("Bookmark This Page", icon: .bookmark, action: #selector(contextMenuBookmark)))
        }

        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Picture in Picture", icon: .pictureInPicture, action: #selector(contextMenuTogglePiP)))
        // Inspect Element is left to WebKit's own default item.
        menu.showItemImages()
    }

    /// WebKit tags its context-menu items with stable identifiers like
    /// `WKMenuItemIdentifierOpenLinkInNewWindow`; match loosely to survive prefix variants.
    static func isOpenInNewWindowItem(_ item: NSMenuItem) -> Bool {
        (item.identifier?.rawValue.localizedCaseInsensitiveContains("OpenLinkInNewWindow")) ?? false
    }

    /// WebKit's identifier for its native "Download Image"/"Download Media" item, if this is one.
    static func isDownloadImageItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.identifier?.rawValue else { return false }
        return id.localizedCaseInsensitiveContains("DownloadImage")
            || id.localizedCaseInsensitiveContains("DownloadMedia")
    }

    /// WebKit's identifier for its native "Download Linked File" item, if this is one.
    static func isDownloadLinkedFileItem(_ item: NSMenuItem) -> Bool {
        (item.identifier?.rawValue.localizedCaseInsensitiveContains("DownloadLinkedFile")) ?? false
    }

    /// WebKit has no hook for context-menu downloads, so native items are retargeted onto `onDownload` (keeping their localized
    /// titles), or one is appended for a known URL. The image item never falls back to `linkURL`, which would download the wrong file.
    private func wireDownloadItems(in menu: NSMenu, imageURL: URL?, linkURL: URL?) {
        var haveImageItem = false
        var haveLinkedItem = false
        for item in menu.items {
            if Self.isDownloadImageItem(item), let url = imageURL, isDownloadable(url) {
                retargetToDownload(item, url: url)
                haveImageItem = true
            } else if Self.isDownloadLinkedFileItem(item), let url = linkURL, isDownloadable(url) {
                retargetToDownload(item, url: url)
                haveLinkedItem = true
            }
        }
        if let imageURL, !haveImageItem, isDownloadable(imageURL) {
            menu.addItem(.separator())
            menu.addItem(makeDownloadItem("Download Image", url: imageURL))
        }
        if let linkURL, !haveLinkedItem, imageURL == nil, isDownloadable(linkURL) {
            menu.addItem(makeDownloadItem("Download Linked File", url: linkURL))
        }
    }

    private func retargetToDownload(_ item: NSMenuItem, url: URL) {
        item.target = self
        item.action = #selector(contextMenuDownload(_:))
        item.representedObject = url
        item.isEnabled = true
    }

    private func makeMenuItem(_ title: String, icon: MenuIcon, action: Selector, isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title.localized, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = isEnabled; item.image = icon.image; return item
    }

    private func makeLinkItem(_ title: String, icon: MenuIcon, action: Selector, url: URL) -> NSMenuItem {
        let item = makeMenuItem(title, icon: icon, action: action); item.representedObject = url; return item
    }

    private func makeDownloadItem(_ title: String, url: URL) -> NSMenuItem {
        makeLinkItem(title, icon: .download, action: #selector(contextMenuDownload(_:)), url: url)
    }

    @objc private func contextMenuSearchWeb() { onSearchWeb() }

    @objc private func contextMenuDownload(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onDownload(url)
    }

    @objc private func contextMenuOpenLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab(url)
    }

    @objc private func contextMenuOpenLinkInNewWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewWindow(url)
    }

    @objc private func contextMenuOpenLinkInNewPrivateSpace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInPrivateSpace(url)
    }

    @objc private func contextMenuBack() { webView.goBack() }
    @objc private func contextMenuForward() { webView.goForward() }
    @objc private func contextMenuReload() { webView.reload() }

    @objc private func contextMenuCopyURL(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
    }

    @objc private func contextMenuTogglePiP() { onTogglePiP() }
    @objc private func contextMenuBookmark() { onBookmark() }
}
