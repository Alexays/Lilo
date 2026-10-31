import WebKit

/// Hides what GenericCosmetics.js finds with user style sheets scoped to the page's web view, as Chrome extensions do: a page
/// can neither see nor remove them, and their `!important` outranks all of its own. Without the SPI, the script adopts a sheet.
@MainActor
final class CosmeticStyleSheets: NSObject, WKScriptMessageHandler {
    static let shared = CosmeticStyleSheets()
    static let messageHandlerName = "liloCosmetics"

    private static let addSelector = NSSelectorFromString("_addUserStyleSheet:")
    private static let removeSelector = NSSelectorFromString("_removeUserStyleSheet:")

    /// `_WKUserStyleSheet`'s initializer for a user-level, main-frame sheet that only `webView`'s page gets; nil without the SPI.
    private static let makeSheet: ((String, WKWebView) -> NSObject)? = {
        let initializer = NSSelectorFromString(
            "initWithSource:forWKWebView:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:baseURL:level:contentWorld:"
        )
        let alloc = NSSelectorFromString("alloc")
        guard let sheetClass = NSClassFromString("_WKUserStyleSheet"), sheetClass.instancesRespond(to: initializer),
              WKUserContentController.instancesRespond(to: addSelector), WKUserContentController.instancesRespond(to: removeSelector),
              let allocMethod = class_getClassMethod(sheetClass, alloc),
              let initImplementation = class_getMethodImplementation(sheetClass, initializer) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, NSString, WKWebView, Bool, NSArray?, NSArray?, NSURL?, Int,
                                         WKContentWorld?) -> Unmanaged<NSObject>
        let allocate = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let initialize = unsafeBitCast(initImplementation, to: Init.self)
        return { source, webView in
            // `alloc` hands over a +1 instance that the initializer consumes; it returns its own +1. Level 0 is `_WKUserStyleUserLevel`.
            initialize(allocate(sheetClass, alloc), initializer, source as NSString, webView, true, nil, nil, nil, 0, nil).takeRetainedValue()
        }
    }()

    static var isSupported: Bool { makeSheet != nil }

    /// The sheets a web view's page got, held by the web view so they also leave the controller, which others share, with it.
    private final class Page: NSObject {
        nonisolated(unsafe) static var key: UInt8 = 0
        let controller: WKUserContentController
        var sheets: [NSObject] = []
        init(controller: WKUserContentController) { self.controller = controller }
        deinit { sheets.forEach { _ = controller.perform(NSSelectorFromString("_removeUserStyleSheet:"), with: $0) } }
    }

    /// Each message is one batch of new rules: added as a sheet of its own, so the earlier ones are neither resent nor parsed again.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let css = message.body as? String, let webView = message.webView,
              // After a process swap, the last page's process may still post once the next page has committed.
              message.frameInfo.securityOrigin.host == webView.url?.host ?? "",
              let sheet = Self.makeSheet?(css, webView) else { return }
        let page = objc_getAssociatedObject(webView, &Page.key) as? Page ?? {
            let page = Page(controller: controller)
            objc_setAssociatedObject(webView, &Page.key, page, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return page
        }()
        _ = controller.perform(Self.addSelector, with: sheet)
        page.sheets.append(sheet)
    }

    /// When the web view commits another document or closes. WebKit applies a sheet to the document it reached only, but keeps it
    /// in the controller, which hands it to every web process it starts.
    func removeSheets(of webView: WKWebView) {
        objc_setAssociatedObject(webView, &Page.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
