import WebKit

/// Lilo's page-world APIs (notifications, geolocation, Web Serial, EyeDropper, tab sharing, media and freeze control),
/// written to leave a page, and so a bot detector, nothing Safari's own pages would not show: their functions read as
/// native code, no global appears, and the bridge handlers live in `bridgeWorld`, as a page world with a handler gets
/// `window.webkit`. The two worlds talk over DOM events whose types are random per launch.
@MainActor
enum PageWorld {
    static let bridgeWorld = WKContentWorld.world(name: "lilo-bridge")

    private static let channel = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// Installs the relay and `modules`, sources of functions run at document start in every frame. Handlers they post to
    /// are registered in `bridgeWorld`; `push` reaches what they hand to `lilo.on`.
    static func install(_ modules: [String], on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: relaySource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: bridgeWorld))
        let page = toolkitSource.replacingOccurrences(of: "__LILO_MODULES__", with: modules.map { "try { (\($0))(); } catch (e) {}" }.joined(separator: "\n"))
        controller.addUserScript(WKUserScript(source: page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    /// JavaScript to run in `bridgeWorld`, in the frame to reach: hands `event` to the page world's handler and returns
    /// what that handler returned. With a user gesture, the handler runs inside it.
    static func push(_ event: String, _ arguments: [Any] = []) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["e": event, "a": arguments]),
              let message = String(bytes: data, encoding: .utf8) else { return "" }
        return "push(\(message))"
    }

    private static func channelSpliced(_ source: String) -> String {
        source.replacingOccurrences(of: "__LILO_REQUEST__", with: channel + "q").replacingOccurrences(of: "__LILO_REPLY__", with: channel + "r")
            .replacingOccurrences(of: "__LILO_SHARE__", with: channel + "s")
    }

    private static let relaySource = channelSpliced(#"""
    (function () {
      'use strict';
      // Absent until a handler is registered in this world.
      const handlers = window.webkit ? window.webkit.messageHandlers : {};
      let answer;
      document.addEventListener('__LILO_REQUEST__', event => {
        const message = JSON.parse(event.detail);
        if (!('h' in message)) { answer = message.r; return; }
        let reply;
        try { reply = Promise.resolve(handlers[message.h].postMessage(message.b)); } catch (error) { reply = Promise.reject(error); }
        if (message.id === undefined) return void reply.catch(() => {});
        reply.then(v => send({ id: message.id, v }), error => send({ id: message.id, x: String(error && error.message || error) }));
      });
      function send(message) { document.dispatchEvent(new CustomEvent('__LILO_REPLY__', { detail: JSON.stringify(message) })); }
      // Dispatch is synchronous: the page world's answer to a push arrives before it returns.
      window.push = message => { answer = undefined; send(message); return answer; };
    })();
    """#)

    /// Every native the toolkit and modules use is captured here, before any page script can wrap it.
    private static let toolkitSource = channelSpliced(#"""
    (function () {
      'use strict';
      const { apply, construct, defineProperty, getOwnPropertyDescriptor, ownKeys } = Reflect;
      const { assign, create } = Object;
      const { stringify, parse } = JSON;
      const listen = EventTarget.prototype.addEventListener, dispatch = EventTarget.prototype.dispatchEvent;
      const NativeCustomEvent = CustomEvent, NativeEvent = Event, NativeError = Error, NativePromise = Promise, NativeTypeError = TypeError;
      const doc = document, nativeToString = Function.prototype.toString;
      // Shared with same-origin frames, as one realm's toString can be called on another's functions.
      let masked;
      try {
        if (window.parent !== window) {
          const ask = new NativeCustomEvent('__LILO_SHARE__', { __proto__: null, detail: {} });
          apply(dispatch, window.parent.document, [ask]);
          masked = ask.detail.masked;
        }
      } catch (e) {}
      masked = masked || new WeakMap();
      apply(listen, doc, ['__LILO_SHARE__', event => { event.detail.masked = masked; }]);
      // Also holds navigator.credentials for the page's life: WebKit hands out a new one once nothing references it,
      // without what the page or a password manager's passkey hook set on it.
      masked.set(navigator, navigator.credentials);
      const toString = { toString() {
        const name = typeof this === 'function' ? masked.get(this) : undefined;
        return name === undefined ? apply(nativeToString, this, arguments) : 'function ' + name + '() {\n    [native code]\n}';
      } }.toString;
      masked.set(toString, 'toString');
      defineProperty(Function.prototype, 'toString', { value: toString });

      const pending = create(null), handlers = create(null);
      let nextId = 0;
      function send(message) { apply(dispatch, doc, [new NativeCustomEvent('__LILO_REQUEST__', { __proto__: null, detail: stringify(message) })]); }
      apply(listen, doc, ['__LILO_REPLY__', event => {
        const message = parse(event.detail);
        if (message.id === undefined) {
          const handler = handlers[message.e];
          const result = handler ? apply(handler, undefined, message.a) : undefined;
          if (result !== undefined) send({ r: result });
          return;
        }
        const settle = pending[message.id];
        delete pending[message.id];
        if (settle) settle(message);
      }]);

      // Interface members as WebIDL defines them: enumerable, configurable, and printed as native code.
      function member(target, key, descriptor) {
        const existing = getOwnPropertyDescriptor(target, key);
        defineProperty(target, key, assign({ enumerable: existing ? existing.enumerable : true, configurable: true }, descriptor));
      }
      const lilo = {
        // Posts `body` to the bridge handler `handler`; resolves with its reply.
        post(handler, body) {
          const id = ++nextId;
          return new NativePromise((resolve, reject) => {
            pending[id] = message => 'x' in message ? reject(new NativeError(message.x)) : resolve(message.v);
            send({ id, h: handler, b: body });
          });
        },
        send(handler, body) { send({ h: handler, b: body }); },
        on(event, handler) { handlers[event] = handler; },
        native(fn, name) { masked.set(fn, name); return fn; },
        // Replaces or adds `target`'s methods with those of `methods`; returns the replaced ones.
        methods(target, methods) {
          const replaced = create(null);
          for (const key of ownKeys(methods)) {
            const fn = methods[key], existing = getOwnPropertyDescriptor(target, key);
            if (existing && typeof existing.value === 'function') {
              replaced[key] = existing.value;
              defineProperty(fn, 'length', { value: existing.value.length });
            }
            masked.set(fn, key);
            member(target, key, { value: fn, writable: true });
          }
          return replaced;
        },
        // Replaces or adds `target`'s accessors with those of `accessors`; returns the replaced getters.
        accessors(target, accessors) {
          const replaced = create(null);
          for (const key of ownKeys(accessors)) {
            const { get, set } = getOwnPropertyDescriptor(accessors, key), existing = getOwnPropertyDescriptor(target, key);
            if (existing && existing.get) replaced[key] = existing.get;
            if (get) masked.set(get, key);
            if (set) masked.set(set, key);
            member(target, key, { get, set });
          }
          return replaced;
        },
        // `on<type>` event handler attributes on `prototype`; returns what wires an instance to them.
        eventHandlers(prototype, types) {
          const attached = new WeakMap();
          for (const type of types) {
            lilo.accessors(prototype, { get ['on' + type]() { const h = attached.get(this); return h && h[type] || null; },
                                        set ['on' + type](value) { const h = attached.get(this); if (h) h[type] = typeof value === 'function' ? value : null; } });
          }
          return instance => {
            const h = create(null);
            attached.set(instance, h);
            for (const type of types) apply(listen, instance, [type, event => { if (h[type]) apply(h[type], instance, [event]); }]);
          };
        },
        // A class standing in for a native interface: printed as native code, members enumerable, tagged with its name.
        nativeClass(cls) {
          masked.set(cls, cls.name);
          // Interfaces without a constructor operation take no arguments.
          defineProperty(cls, 'length', { value: 0 });
          for (const target of [cls, cls.prototype]) {
            for (const key of ownKeys(target)) {
              if (key === 'constructor' || key === 'prototype' || key === 'length' || key === 'name') continue;
              const descriptor = getOwnPropertyDescriptor(target, key);
              for (const fn of [descriptor.value, descriptor.get, descriptor.set]) if (typeof fn === 'function') masked.set(fn, key);
              if (target === cls.prototype) defineProperty(target, key, { enumerable: true });
            }
          }
          defineProperty(cls.prototype, Symbol.toStringTag, { value: cls.name, configurable: true });
          return cls;
        },
        // A global as an interface object is one: writable, configurable, not enumerable.
        global(key, value) { defineProperty(window, key, { value, writable: true, enumerable: false, configurable: true }); },
      };
      // Modules run inside this closure: they use its natives too.
      __LILO_MODULES__
    })();
    """#)
}
