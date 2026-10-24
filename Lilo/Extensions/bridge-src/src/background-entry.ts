// Prelude of every extension service worker: WebKit provides the baseline chrome.* there but none of the gap APIs.
// Must not reference window/document/webkit/messageHandlers (assert-background-prelude-safe.mjs).

import { collectGapListeners, sendGapListeners } from './shared/gap-event.ts';
import { workerReady } from './shared/ipc.ts';
import { recordErrorDiagnostics } from './shared/error-diagnostics.ts';
import { installWorkerWebSocket } from './shared/web-socket.ts';
import { installCredentialedFetch } from './shared/credentialed-fetch.ts';
import { registrationsSettled } from './shared/chrome-leniency.ts';
import { installWasmMimeCompat } from './shared/wasm-mime.ts';
import { skipEmptyImports } from './shared/empty-imports.ts';
import { installWorkerClientMessages } from './shared/worker-messages.ts';
import { installGapAPIs } from './shared/install-gap-apis.ts';
import { installChromeCompat } from './shared/chrome-compat.ts';
import { actionColorAugmentation } from './augmentation/action.ts';
import { showChromeUserAgent } from './shared/chrome-version.ts';

// openPopup stays WebKit's own here: the gap path opens the popup of the calling page's window.
const { openPopup: _pageOnlyOpenPopup, ...workerActionAugmentation } = actionColorAugmentation;

if (!(globalThis as any).__liloBackgroundPreludeInstalled) {
  (globalThis as any).__liloBackgroundPreludeInstalled = true;

  // An uncaught throw at worker global scope aborts the worker before the extension's background script runs, so each
  // stage is isolated: a failure degrades that one API and never stops later stages (notably the channel to Lilo).
  const preludeStage = (stage: string, run: () => void) => {
    try {
      run();
    } catch (err) {
      try { console.error(`[lilo-prelude] stage "${stage}" failed (continuing):`, err); } catch { /* logging must never throw */ }
    }
  };

  preludeStage('install-gap-apis', () => {
    const c: any = (globalThis as any).chrome ?? {};
    (globalThis as any).chrome = c;
    installGapAPIs(c);
  });

  preludeStage('chrome-compat', () => {
    installChromeCompat(workerActionAugmentation);
  });

  // Chrome registers the vendor worker itself, and extensions check `location` (Keeper refuses to run
  // anywhere but its BG.js); relative URLs still resolve against the wrapper, in the same directory.
  // It stays a WorkerLocation, which Mendeley checks to tell its worker from a page.
  preludeStage('location', () => {
    const g = globalThis as any;
    if (typeof g.__liloWorkerScript !== 'string') return;
    const url = new URL(g.__liloWorkerScript, g.location.href);
    const { href, origin, protocol, host, hostname, port, pathname, search, hash } = url;
    const location = Object.setPrototypeOf(
      { href, origin, protocol, host, hostname, port, pathname, search, hash, toString: () => href },
      Object.getPrototypeOf(g.location),
    );
    Object.defineProperty(g, 'location', { configurable: true, enumerable: true, get: () => location });
  });

  // Workers read their browser from the user agent, as in Chrome (Free Download Manager reads its version).
  preludeStage('user-agent', () => {
    showChromeUserAgent(navigator);
  });

  preludeStage('error-diagnostics', () => {
    recordErrorDiagnostics(globalThis, 'worker');
  });

  preludeStage('web-socket', () => {
    installWorkerWebSocket(globalThis);
  });

  preludeStage('credentialed-fetch', () => {
    installCredentialedFetch(globalThis);
  });

  preludeStage('empty-imports', () => {
    skipEmptyImports(globalThis as any, (globalThis as any).__liloEmptyScripts ?? []);
  });

  preludeStage('wasm-mime', () => {
    installWasmMimeCompat(globalThis as any);
  });

  preludeStage('worker-messages', () => {
    installWorkerClientMessages(globalThis);
  });

  // The wrapper calls this once the extension's top-level code has run: its listeners go to Lilo in
  // one report, then the events that woke the worker follow.
  preludeStage('ready', () => {
    collectGapListeners();
    (globalThis as any).__liloWorkerReady = () => {
      delete (globalThis as any).__liloWorkerReady;
      sendGapListeners();
      // As in Chrome, the events go after the answers to the calls the top-level code made (Glasp's
      // contextMenus.removeAll): WebKit can deliver a port message first, never a later call's answer.
      const ready = () => registrationsSettled().then(workerReady);
      const answered = (globalThis as any).browser?.permissions?.getAll?.();
      if (answered) answered.then(ready, ready);
      else ready();
    };
  });
}
