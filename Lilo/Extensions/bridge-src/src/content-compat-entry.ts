// Injected as every extension's first content script: the isolated world never gets ChromeAPIAugmentation.js, so the
// APIs WebKit omits there (chrome.storage.managed) are installed here, before the extension's own content scripts.
import { installStaticChromeCompat } from './shared/static-compat.ts';
import { showChromeUserAgent } from './shared/chrome-version.ts';
import { answerAsChrome } from './shared/message-answers.ts';

installStaticChromeCompat(globalThis as any);

// WebKit finds the world's listeners through its own `browser`, else `chrome`: Proton Pass hides both behind proxies
// once loaded, which would leave its content script without tabs.sendMessage.
const browser = (globalThis as any).browser;
if (browser) Object.defineProperty(globalThis, 'browser', { get: () => browser, set() {}, configurable: true });

const onMessage = (globalThis as any).chrome?.runtime?.onMessage;
if (onMessage && !Object.hasOwn(globalThis, '__liloOnMessage')) {
  answerAsChrome(onMessage);
  // WebKit recreates a collected event object without the members answerAsChrome adds.
  Object.defineProperty(globalThis, '__liloOnMessage', { value: onMessage });
}

// Content scripts read their browser from the user agent, as in Chrome; the page keeps Lilo's own.
try {
  showChromeUserAgent(navigator);
} catch { /* a frozen navigator keeps the page's user agent */ }
