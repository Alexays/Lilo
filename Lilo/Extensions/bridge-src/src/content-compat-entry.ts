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
