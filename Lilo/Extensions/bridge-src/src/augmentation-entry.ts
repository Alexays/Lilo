import { installWasmMimeCompat } from './shared/wasm-mime.ts';
import { installCredentialedFetch } from './shared/credentialed-fetch.ts';
import { installGapAPIs } from './shared/install-gap-apis.ts';
import { closePage, installChromeCompat } from './shared/chrome-compat.ts';
import { actionColorAugmentation } from './augmentation/action.ts';
import { gapModules } from './shared/gap-modules.ts';
import { showChromeUserAgent } from './shared/chrome-version.ts';
import { recordErrorDiagnostics } from './shared/error-diagnostics.ts';
import { installPageWorkerMessages } from './shared/worker-messages.ts';
import { installNetworkInformation } from './shared/network-information.ts';

// Injected into every frame of an extension page; a web page framed there must not see the shims.
const isExtensionOrigin = /^(webkit|chrome)-extension:/.test(String((globalThis as any).origin ?? ''));

if (isExtensionOrigin && !(globalThis as any).__liloAugmentationInstalled) {
  (globalThis as any).__liloAugmentationInstalled = true;

  const c: any = (globalThis as any).chrome ?? {};
  (globalThis as any).chrome = c;

  recordErrorDiagnostics(globalThis, 'page');
  installGapAPIs(c);
  // Chrome offers tabCapture.capture to extension pages only, never to the worker.
  if (c.tabCapture && c.tabCapture === gapModules.tabCapture.tabCaptureAugmentation) {
    c.tabCapture = { ...c.tabCapture, capture: gapModules.tabCapture.captureTab };
  }
  installChromeCompat(actionColorAugmentation, true);
  // A window.close() WebKit accepts ends the page, as in Chrome; Lilo's own close of a detached
  // popup, which replaces window.close, calls __liloPageClosing.
  const g = globalThis as any;
  const close = g.close;
  if (typeof close === 'function') {
    g.close = () => {
      close.call(g);
      if (g.closed) closePage();
    };
  }
  Object.defineProperty(g, '__liloPageClosing', { value: closePage, configurable: true });
  installWasmMimeCompat(globalThis as any);
  installCredentialedFetch(globalThis);
  installPageWorkerMessages(globalThis);
  // A page shown in a tab gets the tabs' user agent; extension code reads Chrome's, as in a popup.
  try {
    showChromeUserAgent(navigator);
  } catch { /* a frozen navigator keeps the tab's user agent */ }
  installNetworkInformation(globalThis);
}
