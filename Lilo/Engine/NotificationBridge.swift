import OSLog
import UserNotifications
import WebKit

// MARK: - NotificationBridge

/// Bridges `window.Notification` to `UNUserNotificationCenter` via a JS polyfill routed through the site-permission UI: WebKit's
/// own permission hook is unimplemented SPI, so the API is denied otherwise. Foreground only, no Web Push.
@MainActor
final class NotificationBridge: NSObject, WKScriptMessageHandler {
    private static let logger = Logger(liloCategory: "notifications")
    static let messageHandlerName = "liloNotification"

    typealias PermissionDecisionHandler = (WKWebView?, String, String, @escaping (Bool) -> Void) -> Void
    var permissionDecisionHandler: PermissionDecisionHandler?

    /// True if the origin already has a stored "allow" decision; gates `new Notification()`.
    var allowanceHandler: ((String) -> Bool)?

    /// The tab a web view belongs to, carried by each notification so a click can bring it back.
    var tabIdResolver: ((WKWebView) -> UUID?)?

    /// Notifications on screen by request identifier: the frame that posted each one and its id there.
    private struct Posted {
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let pageId: Int
    }
    private var posted: [String: Posted] = [:]

    private var didRequestSystemAuthorization = false

    // MARK: WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let origin = message.frameInfo.securityOrigin.permissionOriginKey

        switch type {
        case "requestPermission":
            guard let id = body["id"] as? Int else { return }
            guard message.frameInfo.securityOrigin.isPotentiallyTrustworthy else {
                if let webView = message.webView {
                    WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.__liloNotifyPermission(\(id),'denied');", in: message.frameInfo)
                }
                return
            }
            // The polyfill's pending table is per frame; the reply targets the requesting frame.
            requestPermission(origin: origin, webView: message.webView) { [frame = message.frameInfo] granted in
                // The prompt can outlive the tab going frozen; the page then keeps its pending request.
                guard let webView = frame.webView, !CompositeFreezer.suspendedWebViews.contains(webView) else { return }
                WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.__liloNotifyPermission(\(id),'\(granted ? "granted" : "denied")');", in: frame)
            }
        case "show":
            guard allowanceHandler?(origin) == true else { return }
            show(body: body, message: message, origin: origin)
        case "close":
            guard let pageId = body["id"] as? Int,
                  let identifier = posted.first(where: { $0.value.webView === message.webView && $0.value.pageId == pageId })?.key
            else { return }
            posted[identifier] = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        case "query":
            // Only "allow" is stored as a distinct answer; anything else stays "default" so a site
            // with no decision yet can still prompt.
            guard allowanceHandler?(origin) == true else { return }
            if let webView = message.frameInfo.webView {
                WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.__liloNotifySetPermission('granted');", in: message.frameInfo)
            }
        default:
            break
        }
    }

    // MARK: Private

    private func requestPermission(origin: String, webView: WKWebView?, completion: @escaping (Bool) -> Void) {
        guard let permissionDecisionHandler else { completion(false); return }
        permissionDecisionHandler(webView, "notifications", origin) { [weak self] granted in
            if granted { self?.ensureSystemAuthorization() }
            completion(granted)
        }
    }

    /// One app-wide macOS authorization (per-site allow/deny lives in the site-permission store),
    /// requested lazily the first time a site is granted.
    private func ensureSystemAuthorization() {
        guard !didRequestSystemAuthorization else { return }
        didRequestSystemAuthorization = true
        let logger = Self.logger   // avoid referencing the @MainActor static from the @Sendable closure
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { logger.error("notification authorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Runs the page's click handlers for a notification the user clicked; a no-op once its page is gone.
    func dispatchClick(identifier: String) {
        guard let entry = posted.removeValue(forKey: identifier), let webView = entry.webView else { return }
        webView.evaluateJavaScript("window.__liloNotifyClick?.(\(entry.pageId));", in: entry.frame, in: .page)
    }

    private func show(body: [String: Any], message: WKScriptMessage, origin: String) {
        let content = UNMutableNotificationContent()
        content.title = (body["title"] as? String) ?? ""
        // The site: the page picks the title, so it alone could pass for another site.
        content.subtitle = message.frameInfo.securityOrigin.host
        if let text = body["body"] as? String, !text.isEmpty { content.body = text }
        content.sound = .default
        content.threadIdentifier = origin
        // A tag replaces the same site's earlier notification, never another site's.
        let tag = (body["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let identifier = "web-\(origin)-\(tag)"
        var userInfo: [String: Any] = ["webNotification": identifier]
        if let webView = message.webView, let tabId = tabIdResolver?(webView) { userInfo["webTabId"] = tabId.uuidString }
        content.userInfo = userInfo
        if let pageId = body["id"] as? Int {
            posted = posted.filter { $0.value.webView != nil }
            posted[identifier] = Posted(webView: message.webView, frame: message.frameInfo, pageId: pageId)
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let logger = Self.logger   // avoid referencing the @MainActor static from the @Sendable closure
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("notification delivery failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

// MARK: - Polyfill source

extension NotificationBridge {
    /// JS polyfill injected at document start to override `window.Notification`.
    static let polyfillSource: String = """
(function(){
'use strict';
var handler=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.liloNotification;
if(!handler)return;
var permission='default',queried=false,nextId=1,pending={},shown={};
function query(){if(!queried){queried=true;handler.postMessage({type:'query'});}}
window.__liloNotifyPermission=function(id,result){
var cb=pending[id];if(!cb)return;delete pending[id];permission=result;cb(result);
};
window.__liloNotifySetPermission=function(result){permission=result;};
window.__liloNotifyClick=function(id){
var n=shown[id];if(!n)return;delete shown[id];
n.dispatchEvent({type:'click',target:n,currentTarget:n,defaultPrevented:false,preventDefault:function(){this.defaultPrevented=true;}});
};
function requestPermission(deprecatedCallback){
return new Promise(function(resolve){
var id=nextId++;
pending[id]=function(result){if(typeof deprecatedCallback==='function'){try{deprecatedCallback(result);}catch(e){}}resolve(result);};
handler.postMessage({type:'requestPermission',id:id});
});
}
function LiloNotification(title,options){
options=options||{};
this.title=title==null?'':String(title);this.body=options.body||'';this.icon=options.icon||'';this.tag=options.tag||'';
this.onclick=null;this.onclose=null;this.onerror=null;this.onshow=null;
this._id=nextId++;this._listeners={};shown[this._id]=this;
handler.postMessage({type:'show',id:this._id,title:this.title,body:this.body,icon:this.icon,tag:this.tag});
}
LiloNotification.prototype.close=function(){
if(!shown[this._id])return;delete shown[this._id];handler.postMessage({type:'close',id:this._id});
};
LiloNotification.prototype.addEventListener=function(type,fn){
if(typeof fn!=='function')return;var l=this._listeners[type]||(this._listeners[type]=[]);if(l.indexOf(fn)<0)l.push(fn);
};
LiloNotification.prototype.removeEventListener=function(type,fn){
var l=this._listeners[type];if(l)this._listeners[type]=l.filter(function(f){return f!==fn;});
};
LiloNotification.prototype.dispatchEvent=function(event){
var self=this,handlers=(this._listeners[event.type]||[]).slice(),on=this['on'+event.type];
if(typeof on==='function')handlers.unshift(on);
handlers.forEach(function(fn){try{fn.call(self,event);}catch(e){}});
return !event.defaultPrevented;
};
Object.defineProperty(LiloNotification,'permission',{get:function(){query();return permission;},enumerable:true});
LiloNotification.requestPermission=requestPermission;
LiloNotification.maxActions=0;
try{Object.defineProperty(window,'Notification',{value:LiloNotification,writable:true,configurable:true});}
catch(e){try{window.Notification=LiloNotification;}catch(e2){}}
// Subframes query on first read;
// only the top document pays a native round trip per navigation.
if(window.top===window)query();
})();
"""
}
