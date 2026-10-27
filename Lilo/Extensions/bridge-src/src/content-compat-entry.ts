// Injected as every extension's first content script: the isolated world never gets ChromeAPIAugmentation.js, so the
// APIs WebKit omits there (chrome.storage.managed) are installed here, before the extension's own content scripts.
import { installStaticChromeCompat } from './shared/static-compat.ts';
import { showChromeUserAgent } from './shared/chrome-version.ts';
import { answerAsChrome, relayExternalMessaging } from './shared/message-answers.ts';
import { relayFrameMessaging } from './shared/frame-messaging.ts';

// ExtensionBackgroundPreparer writes the extension's frame key over it: it must stay a single string literal.
const frameKey = '__LILO_FRAME_KEY__';

// The build's banner skips the whole script in a world where it ran already.
Object.defineProperty(globalThis, '__liloContentCompat', { value: true });

installStaticChromeCompat(globalThis as any);

// WebKit finds the world's listeners through its own `browser`, else `chrome`: Proton Pass hides both behind proxies
// once loaded, which would leave its content script without tabs.sendMessage.
const browser = (globalThis as any).browser;
if (browser) Object.defineProperty(globalThis, 'browser', { get: () => browser, set() {}, configurable: true });

// Chrome's events have hasListeners, which WebKit's lack: the world counts each event's listeners on its prototype.
const listeners = new WeakMap<object, Set<unknown>>();
// WebKit's namespaces and events are getters on their object's prototype, which Object.values skips.
const members = (object: any): unknown[] => {
  if (object === null || typeof object !== 'object') return [];
  const names = new Set([...Object.getOwnPropertyNames(object), ...Object.getOwnPropertyNames(Object.getPrototypeOf(object) ?? {})]);
  return [...names].map((name) => { try { return object[name]; } catch { return undefined; } });
};
for (const namespace of members((globalThis as any).chrome)) {
  for (const event of members(namespace)) {
    const prototype = event && typeof (event as any).addListener === 'function' ? Object.getPrototypeOf(event) : undefined;
    if (!prototype || 'hasListeners' in prototype) continue;
    const { addListener, removeListener } = prototype;
    Object.defineProperties(prototype, {
      addListener: { configurable: true, writable: true, value(this: object, listener: unknown, ...rest: unknown[]) {
        const result = addListener.call(this, listener, ...rest);
        if (typeof listener === 'function') (listeners.get(this) ?? listeners.set(this, new Set()).get(this)!).add(listener);
        return result;
      } },
      removeListener: { configurable: true, writable: true, value(this: object, listener: unknown) {
        listeners.get(this)?.delete(listener);
        return removeListener.call(this, listener);
      } },
      hasListeners: { configurable: true, writable: true, value(this: object) { return (listeners.get(this)?.size ?? 0) > 0; } },
    });
  }
}

const onMessage = (globalThis as any).chrome?.runtime?.onMessage;
if (onMessage) {
  answerAsChrome(onMessage);
  // WebKit recreates a collected event object without the members answerAsChrome adds.
  Object.defineProperty(globalThis, '__liloOnMessage', { value: onMessage });
}

const runtime = (globalThis as any).chrome?.runtime;
if (runtime && !Object.hasOwn(globalThis, '__liloRuntime')) {
  relayExternalMessaging(runtime);
  relayFrameMessaging(globalThis, runtime, frameKey);
  // WebKit recreates a collected namespace object, and its prototype, without the relay.
  Object.defineProperty(globalThis, '__liloRuntime', { value: runtime });
}

// Content scripts read their browser from the user agent, as in Chrome; the page keeps Lilo's own.
try {
  showChromeUserAgent(navigator);
} catch { /* a frozen navigator keeps the page's user agent */ }
