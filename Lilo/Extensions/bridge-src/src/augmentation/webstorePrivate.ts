// Injected on every regular tab, so it self-guards on the store hostname before making the store see Lilo as Chrome.

import { CHROME_VERSION, showChromeUserAgentData } from '../shared/chrome-version.ts';

const STORE_HOST = 'chromewebstore.google.com';

// Inert Chrome-style event object, so `chrome.X.onSomething.addListener(...)` never throws.
function inertEvent(): any {
  return { addListener() {}, removeListener() {}, hasListener: () => false };
}

// A real event we can dispatch to, used for management.onInstalled/onUninstalled so the store's
// post-action spinner resolves.
function makeEvent(): any {
  const listeners = new Set<(...a: any[]) => void>();
  return {
    addListener(fn: (...a: any[]) => void) { listeners.add(fn); },
    removeListener(fn: (...a: any[]) => void) { listeners.delete(fn); },
    hasListener(fn: (...a: any[]) => void) { return listeners.has(fn); },
    _fire(...args: any[]) { listeners.forEach((fn) => { try { fn(...args); } catch { /* ignore */ } }); },
  };
}

// Graceful fallback for any store API we didn't implement: an unknown `on*` is an inert event, an
// unknown method a no-op that resolves its trailing callback, so a method we didn't anticipate
// never aborts the store's flow.
function catchMissing(impl: any): any {
  return new Proxy(impl, {
    get(target, prop) {
      if (typeof prop !== 'string' || prop in target) return (target as any)[prop];
      if (prop.startsWith('on')) return inertEvent();
      return (...args: any[]) => {
        const cb = args[args.length - 1];
        if (typeof cb === 'function') { try { cb(undefined); } catch { /* ignore */ } }
        return undefined;
      };
    },
  });
}

// Chrome's dual calling convention: invoke the trailing callback if present, otherwise return a
// Promise (MV3 promisified style).
function method(fn: (...args: any[]) => any): (...args: any[]) => any {
  return (...args: any[]) => {
    const last = args[args.length - 1];
    const hasCb = typeof last === 'function';
    const value = fn(...(hasCb ? args.slice(0, -1) : args));
    if (hasCb) { last(value); return undefined; }
    return Promise.resolve(value);
  };
}

function asyncMethod(fn: (...args: any[]) => Promise<any>): (...args: any[]) => any {
  return (...args: any[]) => {
    const last = args[args.length - 1];
    const hasCb = typeof last === 'function';
    const p = Promise.resolve().then(() => fn(...(hasCb ? args.slice(0, -1) : args)));
    if (hasCb) { p.then((v) => last(v), () => last(undefined)); return undefined; }
    return p;
  };
}

// Round-trip to the native liloWebstore handler. Actions: install / list / uninstall.
function callNative(win: any, payload: any): Promise<any> {
  const mh = win.webkit?.messageHandlers?.liloWebstore;
  if (!mh) return Promise.reject('no_transport');
  return mh.postMessage(payload);
}

// The store's install/remove action is a Material button whose label is this span. Only the word
// "Chrome" (or "Google Chrome") is swapped, so each locale keeps its own wording around it.
const BUTTON_LABEL = 'button > [jsname="V67aGc"]';
const CHROME_NAME = /(?:Google\s)?Chrome/g;

// The store is a SPA that re-renders its button (status, install, remove), so relabel on DOM
// changes, at most once per frame.
function relabelStoreButtons(win: any): void {
  const doc = win.document;
  if (!doc) return;
  let queued = false;
  const relabel = () => {
    queued = false;
    for (const label of doc.querySelectorAll(BUTTON_LABEL)) {
      for (const node of label.childNodes) {
        if (node.nodeType === 3 && node.data.includes('Chrome')) node.data = node.data.replace(CHROME_NAME, 'Lilo');
      }
      const button = label.parentElement;
      const aria = button.getAttribute('aria-label');
      if (aria?.includes('Chrome')) button.setAttribute('aria-label', aria.replace(CHROME_NAME, 'Lilo'));
    }
  };
  new win.MutationObserver(() => {
    if (!queued) { queued = true; win.requestAnimationFrame(relabel); }
  }).observe(doc, { childList: true, subtree: true, characterData: true, attributeFilter: ['aria-label'] });
}

export function installWebstorePrivate(win: any = globalThis as any): void {
  if (win.location?.hostname !== STORE_HOST) return;

  // 1) navigator.userAgentData: the store reads it and getHighEntropyValues to confirm Chrome and
  // compute platform compatibility.
  showChromeUserAgentData(win.navigator);

  const c: any = win.chrome ?? (win.chrome = {});

  // 2) chrome.runtime: real Chrome exposes this on every page; the store probes it.
  if (!c.runtime) {
    c.runtime = {
      id: undefined,
      connect: () => ({ postMessage() {}, disconnect() {}, onMessage: inertEvent(), onDisconnect: inertEvent() }),
      sendMessage: (..._args: any[]) => {},
      onMessage: inertEvent(),
      onMessageExternal: inertEvent(),
      getManifest: () => null,
      lastError: undefined,
    };
  }

  // Installed state comes from the native registry (survives reloads); the events update the store's
  // button live during this page session.
  const onInstalled = makeEvent();
  const onUninstalled = makeEvent();
  function toInfo(e: any): any {
    return {
      id: e.id, name: e.name || e.id, shortName: e.name || e.id, description: '', version: e.version || '',
      enabled: e.enabled !== false, mayDisable: true, installType: 'normal', type: 'extension',
      isApp: false, offlineEnabled: false, optionsUrl: '', hostPermissions: [], permissions: [],
    };
  }
  async function installedList(): Promise<any[]> {
    try { return (await callNative(win, { action: 'list' })) || []; } catch { return []; }
  }

  // 3) chrome.webstorePrivate.
  c.webstorePrivate = catchMissing({
    beginInstallWithManifest3(details: any, cb: (result: string) => void) {
      const finish = (r: string) => { if (typeof cb === 'function') cb(r); };
      callNative(win, { action: 'install', id: details?.id })
        .then((result: string) => {
          // Non-empty results are Chrome result codes ('user_cancelled', 'already_installed').
          if (result) { finish(result); return; }
          finish('');
          onInstalled._fire(toInfo({ id: details?.id, name: details?.localizedName, enabled: true }));
        })
        .catch((err: unknown) => {
          const message = err instanceof Error ? err.message : String(err);
          // Chrome's contract: the result stays a code, the reason is on runtime.lastError while
          // the callback runs.
          c.runtime.lastError = { message };
          try { finish(message === 'user_cancelled' ? 'user_cancelled' : 'installError'); }
          finally { c.runtime.lastError = undefined; }
        });
    },
    completeInstall: method((_id: string) => undefined),
    getExtensionStatus: asyncMethod(async (id: string, _m?: any) => {
      const found = (await installedList()).find((e: any) => e.id === id);
      return found ? (found.enabled !== false ? 'enabled' : 'disabled') : 'installable';
    }),
    getBrowserLogin: method(() => ({ login: '' })),
    getStoreLogin: method(() => ''),
    setStoreLogin: method((_login: string) => undefined),
    getWebGLStatus: method(() => 'webgl_allowed'),
    getIsLauncherEnabled: method(() => false),
    isInIncognitoMode: method(() => false),
    isPendingCustodianApproval: method((_id: string) => false),
    getReferrerChain: method(() => ''),
    // The store reads `.version_number` (not `.version`) and does `.length` on it; set both.
    getFullChromeVersion: method(() => ({ version: CHROME_VERSION, version_number: CHROME_VERSION })),
    getMV2DeprecationStatus: method(() => ({ status: 'inactive' })),
    shouldShowEnterprisePromotionBanner: method(() => false),
  });

  // 4) chrome.management: reflects real installed state + drives uninstall ("Remove from Chrome").
  if (!c.management) {
    c.management = catchMissing({
      getAll: asyncMethod(async () => (await installedList()).map(toInfo)),
      get: asyncMethod(async (id: string) => {
        const found = (await installedList()).find((e: any) => e.id === id);
        return found ? toInfo(found) : undefined;
      }),
      uninstall: asyncMethod(async (id: string) => {
        await callNative(win, { action: 'uninstall', id });
        onUninstalled._fire(id);
        return undefined;
      }),
      onInstalled,
      onUninstalled,
      onEnabled: inertEvent(),
      onDisabled: inertEvent(),
    });
  }

  relabelStoreButtons(win);
}
