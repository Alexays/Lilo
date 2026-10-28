// Lilo's changes to each WebKit chrome.* namespace go on the prototype, which WebKit's `browser` shares: wrapping
// `browser` breaks WebKit. SW-safe: no window/document/webkit.
import { tabGroupsAugmentation, tabsWithGroups, manifestPermissions, discardTab } from '../augmentation/tabGroups.ts';
import { webNavigationAugmentation, webNavigationPatches, webNavigationStandIns } from '../augmentation/webNavigation.ts';
import { actionPatches, alarmsPatches, chromeEvent, contextMenusPatches, i18nPatches, nativeMessagingAsChrome, permissionsPatches, removePageListeners, runtimePatches, scriptingPatches, trackPageListeners } from './chrome-leniency.ts';
import { storageAreaPatches } from './storage-area.ts';
import { answerAsChrome, lastErrorWithoutAnswer, listensProbe, noReceiver } from './message-answers.ts';
import { cookiesOnChanged, cookiesPatches, getPartitionKey } from '../augmentation/cookies.ts';
import {
  runtimeAdditions, runtimeLifecycle, onConnect, onConnectNative, crossExtensionMessaging, crossExtensionPatches, externalEvents, relayForContentScripts, tabsConnect,
} from '../augmentation/runtime.ts';
import { onAuthRequired, webRequestFrames } from '../augmentation/webRequest.ts';
import { chromePageQuery, currentTabOfThisPage, tabsAdditions, onBoundsChanged, tabPatches, tabStandIns, windowPatches } from '../augmentation/tabs.ts';
import { permissionsAdditions } from '../augmentation/permissions.ts';
import { getContexts } from '../augmentation/offscreen.ts';
import { detectLanguage } from '../augmentation/detectLanguage.ts';
import { onUserScriptMessage, onUserScriptConnect } from '../augmentation/userScripts.ts';
import { gapModules } from './gap-modules.ts';
import { ChromeEvent, eventStandIns } from './chrome-event.ts';
import { GapChromeEvent, reportGapListener } from './gap-event.ts';
import { gapCall } from './ipc.ts';
import { callbackify, installBridgeChrome, liloLastError, liloLastErrorMessage, withLastError } from './callbackify.ts';
import { CHROME_CONSTANTS } from './chrome-constants.gen.ts';
import { STATIC_CONSTANTS, addMissing, home } from './static-compat.ts';

export type Method = (this: unknown, ...args: any[]) => any;
/** Wraps WebKit's method; `self(this)` is the namespace, also for a detached call. */
export type Patch = (original: Method, self: (that: unknown) => object) => Method;

export interface NamespaceCompat {
  /** Members WebKit lacks; WebKit's own win. */
  add?: Record<string, unknown>;
  /** Members that replace WebKit's own. */
  replace?: Record<string, unknown>;
  /** WebKit's methods, each replaced once by its patch. */
  patch?: Record<string, Patch>;
  /** WebKit's events whose listeners these events take instead: WebKit's own members cannot be replaced. */
  standIns?: Record<string, ChromeEvent<any>>;
  /** WebKit's own properties, served in their place by the view `chrome` hands out. */
  serve?: (namespace: any) => Record<PropertyKey, unknown>;
  /** The description of each of the namespace's objects (`storage.local`...). */
  members?: Record<string, NamespaceCompat>;
}

// WebKit recreates a collected namespace member (`storage.local`) or event object, and its prototype
// once nothing holds it, without Lilo's additions, patches and stand-ins, even while its namespace lives.
const kept = new Set<object>();

function apply(namespace: object, compat: NamespaceCompat): void {
  const target = home(namespace);
  addMissing(namespace, compat.add);
  for (const name in compat.replace) {
    Object.defineProperty(target, name, { value: compat.replace[name], configurable: true, writable: true });
  }
  for (const name in compat.standIns) {
    const event = (namespace as any)[name];
    if (event) eventStandIns.set(event, compat.standIns[name]);
  }
  const self = (that: unknown) => (target.isPrototypeOf(that) ? that as object : namespace);
  for (const name in compat.patch) {
    const original = target[name];
    if (typeof original !== 'function' || original.__liloUnwrapped) continue;
    const patched = compat.patch[name](original, self) as Method & { __liloUnwrapped?: Method };
    // Lilo's internal calls that need none of the patch (tabs.ts) call the original directly.
    patched.__liloUnwrapped = original;
    Object.defineProperty(target, name, { value: patched, configurable: true, writable: true });
  }
  for (const name in compat.members) {
    const member = (namespace as any)[name];
    if (member === null || typeof member !== 'object') continue;
    kept.add(member);
    apply(member, compat.members[name]);
  }
}

const eventPrototypes = new WeakSet<object>();

/** Gives `chromeEvent` to each WebKit event prototype `namespace` exposes; WebKit has several. */
function makeEventsChromeLike(namespace: object): void {
  const target = home(namespace);
  const names = target === namespace ? Object.getOwnPropertyNames(namespace) : [...Object.getOwnPropertyNames(namespace), ...Object.getOwnPropertyNames(target)];
  for (const name of names) {
    let event: any;
    try { event = (namespace as any)[name]; } catch { continue; }
    if (event === null || typeof event !== 'object' || typeof event.addListener !== 'function' || event instanceof ChromeEvent) continue;
    kept.add(event);
    const prototype = Object.getPrototypeOf(event);
    if (eventPrototypes.has(prototype)) continue;
    eventPrototypes.add(prototype);
    apply(event, chromeEvent);
  }
}

/**
 * Chrome's own, enumerable members, callable detached (`const { getManifest } = chrome.runtime`): WebKit keeps its
 * methods on the prototype, where a detached call has no namespace and returns undefined.
 */
function ownMembers(namespace: any): void {
  const target = home(namespace);
  if (target === namespace) return;
  for (const name of Object.getOwnPropertyNames(target)) {
    const method = Object.getOwnPropertyDescriptor(target, name)?.value;
    if (typeof method !== 'function' || name === 'constructor' || Object.hasOwn(namespace, name)) continue;
    const bound: Method & { __liloUnwrapped?: Method } = chromeMethod(method, namespace);
    // Bound too: Lilo calls it on what `chrome` hands out, a view WebKit's native methods do not take as `this`.
    if (method.__liloUnwrapped) bound.__liloUnwrapped = method.__liloUnwrapped.bind(namespace);
    Object.defineProperty(namespace, name, { value: bound, enumerable: true, configurable: true, writable: true });
  }
  for (const name of Object.getOwnPropertyNames(namespace)) {
    let member: any;
    try { member = namespace[name]; } catch { continue; }
    // WebKit's sub-namespaces have a prototype without a constructor, unlike an array or an error.
    if (member === null || typeof member !== 'object' || typeof member.addListener === 'function') continue;
    if (Object.hasOwn(Object.getPrototypeOf(member) ?? {}, 'constructor')) continue;
    kept.add(member);
    ownMembers(member);
  }
}

/** Whether the page called a window.close() that succeeded; undefined in a worker. */
let pageClosed: boolean | undefined;
const never = new Promise<never>(() => {});

/** WebKit's runtime, whose lastError holds while one of its callbacks runs (Lilo's patches give their own). */
let webKitRuntime: any;

/** Chrome's words for an error of WebKit's from a call with `args`, if Chrome has its own (extensions test them). */
function chromeError(message: string, args: any[]): string | undefined {
  const call = /^Invalid call to ([\w.]+)\(\)\. (.+)$/.exec(message);
  if (!call) return undefined;
  const [, method, error] = call;
  const details = args[0] !== null && typeof args[0] === 'object' ? args[0] : undefined;
  if (error === 'Tab not found.') {
    if (method === 'tabs.sendMessage') return noReceiver;
    const tabId = typeof args[0] === 'number' ? args[0] : details?.tabId;
    return typeof tabId === 'number' ? `No tab with id: ${tabId}.` : undefined;
  }
  // tabs.remove and the calls taking several tabs name the one missing.
  const missing = /^Tab '(\d+)' was not found\.$/.exec(error);
  if (missing) return `No tab with id: ${missing[1]}.`;
  // Chrome names the page to an extension that may read tab urls: the extensions that test it test the start.
  if (error === 'This extension does not have access to this tab.' && /^(scripting|tabs)\.(executeScript|insertCSS|removeCSS)$/.test(method)) {
    return 'Cannot access contents of the page. Extension manifest must request permission to access the respective host.';
  }
  if (error === 'Parent menu item not found.' && details?.parentId !== undefined) return `Cannot find menu item with id ${details.parentId}`;
  if (error === 'Identifier is already used.' && details?.id !== undefined) return `Cannot create item with duplicate id ${details.id}`;
  return undefined;
}

/**
 * `method` on `namespace`, failing in Chrome's words where WebKit's differ; in a page, its callback and promise settle
 * no more once the page closed, as in Chrome.
 */
function chromeMethod(method: Method, namespace: object): Method {
  return function (...args: any[]) {
    const last = args.length - 1;
    const callback = args[last];
    if (typeof callback === 'function') {
      args[last] = function (this: unknown, ...results: unknown[]) {
        if (pageClosed) return undefined;
        const lilo = liloLastErrorMessage();
        const message = lilo ?? webKitRuntime?.lastError?.message;
        const chrome = typeof message === 'string' ? chromeError(message, args) : undefined;
        if (chrome === undefined) return callback.apply(this, results);
        // WebKit's own lastError holds too, which `browser.runtime.lastError` reads unseen (AdBlock's callbacks): its
        // errors go unlogged, as those Lilo leaves in WebKit's words.
        withLastError(chrome, () => callback.apply(this, results), lilo !== undefined);
        return undefined;
      };
    }
    const result = method.apply(namespace, args);
    if (!(result instanceof Promise)) return result;
    return result.then((value) => (pageClosed ? never : value), (error) => {
      if (pageClosed) return never;
      const chrome = error instanceof Error ? chromeError(error.message, args) : undefined;
      return Promise.reject(chrome === undefined ? error : new Error(chrome));
    });
  };
}

/**
 * Runs nothing more of the page, as Chrome after its window.close(): no API callback, promise or event
 * listener. WebKit keeps the page running until the app closes it, a run loop turn later at least.
 */
export function closePage(): void {
  pageClosed = true;
  removePageListeners();
}

/** Chrome's constants for `chrome[name]` and its sub-namespaces, where missing; the hand-written ones first. */
function addConstants(name: string, namespace: object): void {
  addMissing(namespace, STATIC_CONSTANTS[name]);
  for (const path in CHROME_CONSTANTS) {
    if (path !== name && !path.startsWith(`${name}.`)) continue;
    addMissing(path.split('.').slice(1).reduce<any>((o, key) => o?.[key], namespace), CHROME_CONSTANTS[path]);
  }
}

/**
 * A plain object, as WebKit's own properties are neither enumerable nor redefinable and a Proxy costs each read more.
 * WebKit's native methods need their namespace as `this`, so the view holds them bound.
 */
function view(namespace: any, members: Record<PropertyKey, unknown>): object {
  const properties: PropertyDescriptorMap = {};
  for (let object = namespace; object !== null && object !== Object.prototype; object = Object.getPrototypeOf(object)) {
    for (const name of Reflect.ownKeys(object)) {
      if (name === 'constructor' || Object.hasOwn(properties, name) || Object.hasOwn(members, name)) continue;
      let value: unknown;
      try { value = namespace[name]; } catch { continue; }
      // WebKit's methods are not enumerable; the enumerable ones ownMembers made are bound already.
      const native = typeof value === 'function' && !Object.getOwnPropertyDescriptor(object, name)!.enumerable
        && /\[native code\]/.test(Function.prototype.toString.call(value));
      properties[name] = typeof value === 'function'
        ? { value: native ? value.bind(namespace) : value, writable: true, configurable: true, enumerable: true }
        : { get: () => namespace[name], set: (next: unknown) => { namespace[name] = next; }, configurable: true, enumerable: true };
    }
  }
  return Object.create(namespace, { ...properties, ...Object.getOwnPropertyDescriptors(members) });
}

// Native fires it when the user pins the extension to the address bar or unpins it.
const actionOnUserSettingsChanged = new GapChromeEvent<[{ isOnToolbar?: boolean }]>('action', 'onUserSettingsChanged');
// Never fired: Lilo has no blocking webRequest.
const webRequestOnActionIgnored = new ChromeEvent<[unknown]>();

/**
 * Makes `globalThis.chrome` Lilo's proxy over WebKit's, which applies each namespace's description.
 * `action` is the badge color surface this context gets.
 */
export function installChromeCompat(action: Record<string, unknown>, page = false): void {
  const g = globalThis as any;
  pageClosed = page ? false : undefined;
  trackPageListeners(page);
  const chrome = g.chrome;
  webKitRuntime = chrome.runtime;
  const perms = manifestPermissions(chrome);
  const nativeMessaging = perms.has('nativeMessaging');
  // Chrome has runtime.onUserScriptMessage and onUserScriptConnect with the permission, also while chrome.userScripts is
  // hidden or the permission only optional (Table Capture listens before asking for it).
  const userScripts = perms.has('userScripts') || !!chrome.runtime?.getManifest?.()?.optional_permissions?.includes('userScripts');
  const contextMenus: NamespaceCompat = { patch: contextMenusPatches };
  // Chrome reveals every tab's url to an extension that may hold `tabs`, which WebKit ignores: Lilo reads
  // them for it, and leaves out the empty ones WebKit reports to the others.
  const withheldURLs = !perms.has('tabs') && !chrome.runtime?.getManifest?.()?.optional_permissions?.includes('tabs');
  const groups = chrome.tabGroups === tabGroupsAugmentation ? tabsWithGroups : {};
  const unreceived = () => noReceiver;
  // How long each look for a loading tab's content scripts waits: about half a second in all.
  const TAB_LISTENER_WAITS = [20, 60, 150, 300];
  // A page's message goes to the worker and the other pages (an offscreen document): Chrome's error then depends on
  // whether one listens, which their answer to the probe tells, or Lilo for a worker that may not run yet. Its promise
  // rejects when nothing does. A worker's goes to pages, mostly not open: its promise resolves.
  const pageNoAnswer = () => Promise.resolve(chrome.runtime.sendMessage(listensProbe)).catch(() => undefined)
    .then((listens) => listens === true || gapCall<boolean>('runtime', 'workerListensToMessages'))
    .then((listens) => (listens ? 'The message port closed before a response was received.' : noReceiver), unreceived);
  // Asked when nobody answered a tab's message: its content scripts, and the extension's own pages it shows, which
  // WebKit delivers it to as Chrome, answer the probe once one listens. A tab still loading one of those pages counts
  // as listening: its page cannot listen yet (a tab opened on the popup hears tabs.onActivated's message at once).
  // A message sent on a document's DOMContentLoaded reaches no content script yet (WEBKIT-GAPS 97): the probe goes again
  // while the tab loads, and once one listens the message goes too, as nobody received it.
  const tabNoAnswer = (original: Method, self: (that: unknown) => object) => async function (this: unknown, tabId: unknown, message: unknown, options?: unknown) {
    const tabs = self(this) as any;
    const target = options !== null && typeof options === 'object' ? [options] : [];
    const portClosed = 'The message port closed before a response was received.';
    const tab = () => Promise.resolve((tabs.get?.__liloUnwrapped ?? tabs.get)?.call(tabs, tabId)).catch(() => undefined);
    const listens = () => Promise.resolve(original.call(tabs, tabId, listensProbe, ...target)).then((answer) => answer === true, () => false);
    const loadsOwnPage = async () => {
      const shown = await tab();
      const base = chrome.runtime?.getURL?.('');
      const scope = globalThis as any;
      // Chrome never delivers a page's message to the page itself: its own tab does not count.
      const own = scope.top === scope && typeof scope.location?.href === 'string' ? scope.location.href.split('#')[0] : undefined;
      return shown?.status === 'loading' && !!base && [shown.url, shown.pendingUrl]
        .some((url) => typeof url === 'string' && url.startsWith(base) && url.split('#')[0] !== own);
    };
    if (await listens() || await loadsOwnPage()) return portClosed;
    for (const [attempt, delay] of TAB_LISTENER_WAITS.entries()) {
      // The first look also follows a tab that just completed: its document committed a moment ago.
      if (attempt > 0 && (await tab())?.status !== 'loading') break;
      await new Promise((resolve) => setTimeout(resolve, delay));
      if (!await listens()) continue;
      const response = await Promise.resolve(original.call(tabs, tabId, message, ...target)).catch(() => undefined);
      return response === undefined ? portClosed : { response };
    }
    return noReceiver;
  };
  const tabsPatch: Record<string, Patch> = {
    ...tabPatches(withheldURLs),
    sendMessage: (original, self) => lastErrorWithoutAnswer(original, tabNoAnswer(original, self), true),
    connect: tabsConnect,
  };
  const query = tabsPatch.query;
  tabsPatch.query = (original, self) => chromePageQuery(query(original, self), self);
  const getCurrent = tabsPatch.getCurrent;
  tabsPatch.getCurrent = (original, self) => currentTabOfThisPage(getCurrent(original, self), self);
  const runtimeOnConnect = onConnect(() => chrome.runtime.onConnect);
  const compat: Record<string, NamespaceCompat> = {
    // WebKit does not expose badge colors to Swift, so the color calls are bridged onto its chrome.action.
    action: { replace: action, add: { onUserSettingsChanged: actionOnUserSettingsChanged }, patch: actionPatches },
    alarms: { patch: alarmsPatches },
    scripting: { patch: scriptingPatches },
    webNavigation: { add: webNavigationAugmentation, patch: webNavigationPatches, standIns: webNavigationStandIns },
    // WebKit has no tab groups: tabs.group/ungroup and each tab's groupId map onto Lilo folders.
    tabs: { add: { discard: discardTab, ...tabsAdditions }, replace: groups.replace, patch: tabsPatch, standIns: tabStandIns(withheldURLs) },
    // Read only once WebKit gives the namespace, which comes with the permissions its gap module needs.
    get declarativeNetRequest() {
      return gapModules.declarativeNetRequest.declarativeNetRequestCompat?.(chrome.declarativeNetRequest, perms.has('declarativeNetRequestFeedback'));
    },
    windows: { add: { onBoundsChanged }, patch: windowPatches(withheldURLs) },
    permissions: {
      add: permissionsAdditions,
      patch: permissionsPatches(
        () => manifestPermissions(chrome),
        () => chrome.runtime?.getManifest?.()?.host_permissions ?? [],
        () => chrome.runtime?.getManifest?.()?.optional_permissions ?? [],
      ),
    },
    contextMenus,
    menus: contextMenus,
    extension: {
      add: {
        // Lilo updates only Web Store extensions, for which Chrome ignores this value too.
        setUpdateUrlData: (_data: string) => {},
        // Deprecated in Chrome's schemas, so missing from the generated constants, but still there.
        ViewType: { TAB: 'tab', POPUP: 'popup' },
      },
      // Chrome leaves it out of workers, which test it before comparing its page with `window`. WebKit's own
      // member cannot be removed, so `browser.extension` keeps it (WEBKIT-GAPS.md, gap 87).
      serve: page ? undefined : () => ({ getBackgroundPage: undefined }),
    },
    webRequest: {
      add: {
        // Nothing to flush: Lilo's webRequest only observes, so no cached request depends on a handler.
        handlerBehaviorChanged: (callback?: () => void) => callbackify(async () => {}, callback),
        onActionIgnored: webRequestOnActionIgnored,
      },
      standIns: { ...webRequestFrames((name) => chrome.webRequest[name]), onAuthRequired: onAuthRequired(() => chrome.webRequest.onAuthRequired) },
    },
    i18n: { add: { detectLanguage }, patch: i18nPatches },
    runtime: {
      patch: { ...runtimePatches, ...crossExtensionPatches },
      // WebKit's own: an extension may replace globalThis.chrome (Proton Pass).
      standIns: { ...runtimeLifecycle, onConnect: runtimeOnConnect, ...externalEvents(() => chrome.runtime) },
      add: {
        getContexts,
        ...runtimeAdditions,
        ...(nativeMessaging ? { onConnectNative } : {}),
        ...(userScripts ? { onUserScriptMessage, onUserScriptConnect } : {}),
      },
      serve: (runtime) => {
        // Only through chrome: browser.runtime.lastError stays WebKit's (Touch VPN reads it).
        const sendLocal = lastErrorWithoutAnswer((...args: any[]) => runtime.sendMessage(...args), page ? pageNoAnswer : unreceived, page);
        return {
          // WebKit's lastError is null without an error, Chrome's undefined (eJOY tests it with typeof).
          get lastError() { return liloLastError() ?? runtime.lastError ?? undefined; },
          ...(nativeMessaging ? nativeMessagingAsChrome(runtime) : {}),
          ...crossExtensionMessaging(runtime, sendLocal, runtimeOnConnect),
        };
      },
    },
    cookies: { add: { getPartitionKey }, patch: cookiesPatches, standIns: { onChanged: cookiesOnChanged } },
    storage: { members: { local: { patch: storageAreaPatches }, session: { patch: storageAreaPatches }, sync: { patch: storageAreaPatches } } },
  };
  // What `chrome` hands out for each namespace object it has seen: the object itself or its view. It
  // keeps each object alive: WebKit recreates a collected namespace object, without Lilo's additions.
  const handedOut = new Map<object, object>();
  // The namespaces an extension assigned where WebKit keeps its own.
  const assigned = new Map<PropertyKey, unknown>();
  installBridgeChrome(new Proxy(chrome, {
    get(target, property) {
      if (assigned.size && assigned.has(property)) return assigned.get(property);
      const value = Reflect.get(target, property);
      if (typeof property !== 'string' || value === null || typeof value !== 'object') return value;
      const known = handedOut.get(value);
      if (known !== undefined) return known;
      const description = Object.hasOwn(compat, property) ? compat[property] : undefined;
      try {
        if (description) apply(value, description);
        makeEventsChromeLike(value);
        addConstants(property, value);
        ownMembers(value);
      } catch (err) {
        try { console.error(`[lilo] adding to chrome.${property} failed:`, err); } catch { /* logging must never throw */ }
      }
      // Lilo's own namespaces are plain objects, Chrome-shaped already.
      const served = description?.serve || home(value) !== value ? view(value, description?.serve?.(value) ?? {}) : value;
      handedOut.set(value, served);
      return served;
    },
    // WebKit's namespaces cannot be replaced, even by defineProperty, Chrome's can: Distill replaces
    // chrome.storage in its offscreen document. What an extension assigns is handed back untouched.
    set(target, property, value) {
      if (value !== null && typeof value === 'object') handedOut.set(value, value);
      assigned.delete(property);
      if (!Reflect.set(target, property, value) || !Object.is(Reflect.get(target, property), value)) assigned.set(property, value);
      return true;
    },
  }));
  // `browser` shares these objects without going through `chrome`: give the present ones theirs now.
  for (const name of Object.keys(chrome)) void g.chrome[name];
  for (const name in g.browser) void g.chrome[name];
  // WebKit finds a context's listeners through its own `browser`, else `chrome`, which the proxy hides:
  // `var browser = chrome` or webextension-polyfill's `browser` would leave the context without events.
  const browser = g.browser;
  if (browser) Object.defineProperty(g, 'browser', { get: () => browser, set() {}, configurable: true });
  // The worker tells Lilo it listens, for the error of a page's message nobody answers.
  if (g.chrome.runtime?.onMessage) answerAsChrome(g.chrome.runtime.onMessage, page ? undefined : () => reportGapListener('runtime.onMessage'));
  if (!page && chrome.runtime?.onMessage) relayForContentScripts(chrome.runtime);
}
