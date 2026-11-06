import OSLog
import UserNotifications
import WebKit

// MARK: - NotificationBridge

/// Bridges `window.Notification` to `UNUserNotificationCenter` via a JS polyfill routed through the site-permission UI: WebKit's
/// own permission hook is unimplemented SPI, so the API is denied otherwise. As every Lilo data store's delegate, it also gives
/// WebKit each site's decision and shows service workers' notifications. No Web Push.
@MainActor
final class NotificationBridge: NSObject, WKScriptMessageHandler {
    private static let logger = Logger(liloCategory: "notifications")
    static let messageHandlerName = "liloNotification"

    typealias PermissionDecisionHandler = (WKWebView?, String, String, @escaping (Bool) -> Void) -> Void
    var permissionDecisionHandler: PermissionDecisionHandler?

    /// The decision a page's notifications have without asking: true allowed, false blocked, nil to ask.
    var decisionHandler: ((WKWebView?, String) -> Bool?)?

    /// The tab a web view belongs to, carried by each notification so a click can bring it back.
    var tabIdResolver: ((WKWebView) -> UUID?)?

    /// The stored notification decisions of a data store's sites, by origin key (true allowed).
    var storeDecisionsHandler: ((WKWebsiteDataStore) -> [String: Bool])?

    /// Told of each notification a page posts, with the web view that posted it.
    var shownHandler: ((WKWebView) -> Void)?

    /// Notifications on screen by request identifier: the frame that posted each one and its id there.
    private struct Posted {
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let pageId: Int
    }
    private var posted: [String: Posted] = [:]

    /// Service worker notifications on screen by request identifier, with what WebKit needs to hand their worker a click.
    private struct PersistentPosted {
        weak var dataStore: WKWebsiteDataStore?
        let notification: NSDictionary
    }
    private var persistentPosted: [String: PersistentPosted] = [:]

    private var didRequestSystemAuthorization = false

    // MARK: WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let origin = message.frameInfo.securityOrigin.permissionOriginKey
        // Browsers refuse notifications to a frame of another origin than its page's.
        let isCrossOrigin = origin != message.frameInfo.permissionOriginKey

        switch type {
        case "requestPermission":
            guard let id = body["id"] as? Int else { return }
            guard message.frameInfo.securityOrigin.isPotentiallyTrustworthy, !isCrossOrigin else {
                if let webView = message.webView {
                    WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("notifyPermission", [id, "denied"]),
                                                                                in: message.frameInfo, in: PageWorld.bridgeWorld)
                }
                return
            }
            // The polyfill's pending table is per frame; the reply targets the requesting frame.
            requestPermission(origin: origin, webView: message.webView) { [frame = message.frameInfo] granted in
                // The prompt can outlive the tab going frozen; the page then keeps its pending request.
                guard let webView = frame.webView, !CompositeFreezer.suspendedWebViews.contains(webView) else { return }
                WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("notifyPermission", [id, granted ? "granted" : "denied"]),
                                                                            in: frame, in: PageWorld.bridgeWorld)
            }
        case "show":
            guard !isCrossOrigin, decisionHandler?(message.webView, origin) == true else { return }
            show(body: body, message: message, origin: origin)
        case "close":
            guard let pageId = body["id"] as? Int,
                  let identifier = posted.first(where: { $0.value.webView === message.webView && $0.value.pageId == pageId })?.key
            else { return }
            posted[identifier] = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        case "query":
            guard !isCrossOrigin, let webView = message.frameInfo.webView else { return }
            let permission = decisionHandler?(message.webView, origin).map { $0 ? "granted" : "denied" } ?? "default"
            guard permission != body["permission"] as? String else { return }
            WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("notifySetPermission", [permission]),
                                                                        in: message.frameInfo, in: PageWorld.bridgeWorld)
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

    /// Runs the click handlers of the page or service worker that showed a notification the user clicked; a no-op once it is gone.
    func dispatchClick(identifier: String) {
        if let entry = persistentPosted.removeValue(forKey: identifier) {
            let click = NSSelectorFromString("_processPersistentNotificationClick:completionHandler:")
            guard let dataStore = entry.dataStore, dataStore.responds(to: click) else { return }
            typealias Click = @convention(c) (AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
            unsafe unsafeBitCast(dataStore.method(for: click), to: Click.self)(dataStore, click, entry.notification) { _ in }
            return
        }
        guard let entry = posted.removeValue(forKey: identifier), let webView = entry.webView else { return }
        webView.evaluateJavaScript(PageWorld.push("notifyClick", [entry.pageId]), in: entry.frame, in: PageWorld.bridgeWorld)
    }

    private func show(body: [String: Any], message: WKScriptMessage, origin: String) {
        var userInfo: [String: Any] = [:]
        if let webView = message.webView {
            if let tabId = tabIdResolver?(webView) { userInfo["webTabId"] = tabId.uuidString }
            shownHandler?(webView)
        }
        let identifier = post(title: (body["title"] as? String) ?? "", body: body["body"] as? String, tag: body["tag"] as? String,
                              origin: origin, host: message.frameInfo.securityOrigin.host, userInfo: userInfo)
        if let pageId = body["id"] as? Int {
            posted = posted.filter { $0.value.webView != nil }
            posted[identifier] = Posted(webView: message.webView, frame: message.frameInfo, pageId: pageId)
        }
    }

    /// Hands a site's notification to macOS and returns its request identifier.
    private func post(title: String, body: String?, tag: String?, origin: String, host: String, userInfo: [String: Any]) -> String {
        let content = UNMutableNotificationContent()
        content.title = title
        // The site: the page picks the title, so it alone could pass for another site.
        content.subtitle = host
        if let body, !body.isEmpty { content.body = body }
        content.sound = .default
        content.threadIdentifier = origin
        // A tag replaces the same site's earlier notification, never another site's.
        let identifier = "web-\(origin)-\(tag.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString)"
        content.userInfo = userInfo.merging(["webNotification": identifier]) { $1 }
        // The page or the service worker may have shown the one it replaces; the caller records the new one.
        posted[identifier] = nil
        persistentPosted[identifier] = nil
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let logger = Self.logger   // avoid referencing the @MainActor static from the @Sendable closure
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("notification delivery failed: \(error.localizedDescription, privacy: .public)") }
        }
        return identifier
    }
}

// MARK: - Website data store delegate

/// `_WKWebsiteDataStoreDelegate`: WebKit learns each site's decision before a page, worker or service worker runs its first
/// script, and a service worker's `showNotification` goes through Lilo.
extension NotificationBridge {
    @objc(notificationPermissionsForWebsiteDataStore:)
    func notificationPermissions(for dataStore: WKWebsiteDataStore) -> [String: Bool] {
        storeDecisionsHandler?(dataStore) ?? [:]
    }

    @objc(websiteDataStore:showNotification:)
    func websiteDataStore(_ dataStore: WKWebsiteDataStore, showNotification data: NSObject) {
        guard ["title", "body", "tag", "origin", "dictionaryRepresentation"].allSatisfy({ data.responds(to: NSSelectorFromString($0)) }),
              let originValue = data.value(forKey: "origin"),
              let url = originValue as? URL ?? (originValue as? String).flatMap(URL.init(string:)), let scheme = url.scheme, let host = url.host,
              let notification = data.value(forKey: "dictionaryRepresentation") as? NSDictionary
        else { return }
        let origin = PermissionOriginKey.build(scheme: scheme, host: host, port: url.port ?? 0)
        // WebKit's table can trail a decision changed since the worker's process read it.
        guard storeDecisionsHandler?(dataStore)[origin] == true else { return }
        let identifier = post(title: (data.value(forKey: "title") as? String) ?? "", body: data.value(forKey: "body") as? String,
                              tag: data.value(forKey: "tag") as? String, origin: origin, host: host, userInfo: [:])
        persistentPosted = persistentPosted.filter { $0.value.dataStore != nil }
        persistentPosted[identifier] = PersistentPosted(dataStore: dataStore, notification: notification)
    }
}

// MARK: - Page module

extension NotificationBridge {
    /// `window.Notification` for `PageWorld`: WebKit's own interface, its constructor and members swapped for ones that
    /// show through Lilo. Instances are EventTargets on the native prototype, so `instanceof` and events work as there.
    static let pageModule = #"""
    function () {
      const Native = window.Notification;
      if (typeof Native !== 'function') return;
      const prototype = Native.prototype, fields = new WeakMap(), pending = create(null), shown = create(null), shownByTag = create(null);
      let nextId = 1;
      // WebKit's static `permission` is a read-only data property, not a getter.
      const setPermission = value => defineProperty(Notification, 'permission', { value, writable: false, enumerable: true, configurable: true });
      lilo.on('notifyPermission', (id, result) => {
        const callback = pending[id];
        if (!callback) return;
        delete pending[id];
        setPermission(result);
        callback(result);
      });
      lilo.on('notifySetPermission', setPermission);
      lilo.on('notifyClick', id => {
        const notification = shown[id];
        if (!notification) return;
        delete shown[id];
        apply(dispatch, notification, [new NativeEvent('click')]);
      });
      const attach = lilo.eventHandlers(prototype, ownKeys(prototype).filter(key => typeof key === 'string' && key.startsWith('on')).map(key => key.slice(2)));
      const Notification = lilo.native(function Notification(title) {
        if (!new.target) throw new NativeTypeError("Constructor requires 'new' operator");
        if (arguments.length < 1) throw new NativeTypeError('Not enough arguments');
        const options = arguments[1] || {}, notification = construct(EventTarget, [], new.target), id = nextId++;
        const field = key => key in options ? options[key] : key === 'dir' ? 'auto' : key === 'silent' || key === 'data' ? null : '';
        const values = { id, title: String(title), body: String(field('body')), icon: String(field('icon')), tag: String(field('tag')),
                         dir: String(field('dir')), lang: String(field('lang')), silent: field('silent'), data: field('data'), navigate: field('navigate') };
        fields.set(notification, values);
        attach(notification);
        shown[id] = notification;
        // Native replaces the same tag's notification, which may have been dismissed in macOS without the page hearing of it.
        if (values.tag) { delete shown[shownByTag[values.tag]]; shownByTag[values.tag] = id; }
        lilo.send('liloNotification', { type: 'show', id, title: values.title, body: values.body, icon: values.icon, tag: values.tag });
        return notification;
      }, 'Notification');
      defineProperty(Notification, 'prototype', { value: prototype, writable: false });
      // WebKit's own value: the site's decision when Lilo's data store delegate gave it, else "default".
      setPermission(Native.permission);
      lilo.methods(Notification, { requestPermission(deprecatedCallback) {
        return new NativePromise(resolve => {
          const id = nextId++;
          pending[id] = result => {
            if (typeof deprecatedCallback === 'function') { try { deprecatedCallback(result); } catch (e) {} }
            resolve(result);
          };
          lilo.send('liloNotification', { type: 'requestPermission', id });
        });
      } });
      defineProperty(Notification.requestPermission, 'length', { value: Native.requestPermission.length });
      defineProperty(prototype, 'constructor', { value: Notification });
      for (const key of ownKeys(prototype)) {
        const descriptor = getOwnPropertyDescriptor(prototype, key);
        if (typeof key !== 'string' || key.startsWith('on') || !descriptor.get) continue;
        lilo.accessors(prototype, { get [key]() { const values = fields.get(this); return values ? values[key] : undefined; } });
      }
      lilo.methods(prototype, {
        close() {
          const values = fields.get(this);
          if (!values || !shown[values.id]) return;
          delete shown[values.id];
          lilo.send('liloNotification', { type: 'close', id: values.id });
        },
        show() {},
      });
      lilo.global('Notification', Notification);
      // WebKit reads its table when a process starts and knows no global or extension rule, so a secure top origin checks its
      // value; the others cannot hold a decision. A same-origin subframe shares the top's, and browsers deny cross-origin ones.
      if (window.top !== window) {
        try { setPermission(top.Notification.permission); } catch (e) { setPermission('denied'); }
      } else if (window.isSecureContext) {
        // At document start the bridge world's relay may not be listening yet.
        apply(listen, doc, ['DOMContentLoaded', () => lilo.send('liloNotification', { type: 'query', permission: Notification.permission }), { once: true }]);
      }
    }
    """#
}
