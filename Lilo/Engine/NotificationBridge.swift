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

    /// Told of each notification a page posts, with the web view that posted it.
    var shownHandler: ((WKWebView) -> Void)?

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
                WebViewPrivateAccessors(webView).evaluateWithoutUserGesture(PageWorld.push("notifySetPermission", ["granted"]),
                                                                            in: message.frameInfo, in: PageWorld.bridgeWorld)
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
        webView.evaluateJavaScript(PageWorld.push("notifyClick", [entry.pageId]), in: entry.frame, in: PageWorld.bridgeWorld)
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
        if let webView = message.webView {
            if let tabId = tabIdResolver?(webView) { userInfo["webTabId"] = tabId.uuidString }
            shownHandler?(webView)
        }
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
      setPermission('default');
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
      // Only a trustworthy origin can hold a stored allow; the others would pay an IPC for nothing.
      if (isSecureContext && location.origin !== 'null') lilo.send('liloNotification', { type: 'query' });
    }
    """#
}
