// Retries what WebKit rejects and Chrome accepts. Patches go on the prototypes `chrome` and WebKit's `browser` share,
// so extensions reaching the API either way get them. SW-safe: no window/document/webkit.
import { bridgeChrome, callbackify, withLastError } from './callbackify.ts';
import { ChromeEvent, eventStandIns } from './chrome-event.ts';
import { CHANNEL_HOST, gapCall } from './ipc.ts';
import type { NamespaceCompat, Patch } from './chrome-compat.ts';
import { chromeManifest, contentCompat, withoutContentCompat } from './static-compat.ts';

const unknownPermission = /'([^']+)' is not a valid permission/;
const invalidPattern = /'([^']+)' is not a valid pattern/;
const unknownResourceType = /'([^']+)' is an unknown resource type/;
const invalidMatchPattern = /'([^']+)' is an invalid match pattern/;

interface Permissions {
  permissions?: string[];
  origins?: string[];
}

/**
 * Drops each permission WebKit does not know and each origin it rejects (wss:, which Chrome takes); Lilo answers
 * for the dropped ones.
 */
async function withoutUnknownPermissions(request: Permissions, call: (known: Permissions) => Promise<any>): Promise<{ result: any; unknown: string[] }> {
  let known = [...(request?.permissions ?? [])];
  let origins = request?.origins && [...request.origins];
  const unknown: string[] = [];
  for (;;) {
    try {
      return { result: await call({ ...request, permissions: known, ...(origins && { origins }) }), unknown };
    } catch (error) {
      const message = String((error as Error)?.message);
      const name = unknownPermission.exec(message)?.[1];
      const origin = invalidPattern.exec(message)?.[1];
      if (name && known.includes(name)) {
        known = known.filter((permission) => permission !== name);
        unknown.push(name);
      } else if (origin && origins?.includes(origin)) {
        origins = origins.filter((pattern) => pattern !== origin);
        unknown.push(origin);
      } else {
        throw error;
      }
    }
  }
}

const asksForSomething = (request: Permissions) => Boolean(request.permissions?.length || request.origins?.length);

// Lilo grants these to every extension for its own channel to Lilo: an extension holds one when its manifest
// requires it or the user granted it at Lilo's prompt.
const grantedForLilo = new Set(['nativeMessaging']);
const notRequired = (request: Permissions, declared: Set<string>) =>
  (request?.permissions ?? []).filter((name) => grantedForLilo.has(name) && !declared.has(name));
/** The permissions Lilo holds for the extension, as this context last learned them. */
export const heldByLilo = new Set<string>();

/** The manifest's permissions plus the optional ones WebKit grants no request for that the user granted. */
export async function readHeldByLilo(): Promise<Set<string>> {
  const held = await gapCall<string[]>('permissions', 'held');
  heldByLilo.clear();
  held.forEach((name) => heldByLilo.add(name));
  return heldByLilo;
}

export function permissionsPatches(declared: () => Set<string>, declaredOrigins: () => string[], declaredOptional: () => string[]): Record<string, Patch> {
  const isDeclared = (name: string) => declared().has(name) || declaredOrigins().includes(name);
  const withoutNames = (request: Permissions, names: string[]) => ({ ...request, permissions: request?.permissions?.filter((name) => !names.includes(name)) });
  return {
    contains: (original) => function (this: unknown, request: Permissions, callback?: (result: boolean) => void) {
      return callbackify(async () => {
        // Chrome's pattern contains <all_urls> when it matches all of one of its schemes' URLs: an extension holding
        // *://*/* holds it (uBO Lite's forks turn their cosmetic filters on from it). WebKit wants every scheme.
        if (request?.origins?.includes('<all_urls>')) {
          const allOf = async (scheme: string) => Boolean(await original.call(this, { origins: [`${scheme}://*/*`] }).catch(() => false));
          if (!(await allOf('https') || await allOf('http'))) return false;
          request = { ...request, origins: request.origins.filter((origin) => origin !== '<all_urls>') };
        }
        const forLilo = notRequired(request, declared());
        const { result, unknown } = await withoutUnknownPermissions(withoutNames(request, forLilo), (known) => original.call(this, known));
        const asked = [...forLilo, ...unknown].filter((name) => !isDeclared(name));
        if (!result || asked.length === 0) return result;
        const held = await readHeldByLilo();
        return asked.every((name) => held.has(name));
      }, callback);
    },
    request: (original) => function (this: unknown, request: Permissions, callback?: (granted: boolean) => void) {
      return callbackify(async () => {
        let origins = request?.origins && [...request.origins];
        // One prompt for the whole request, Lilo's: WebKit rejects such a request before it prompts.
        const promptedByLilo = async () => {
          const granted = await gapCall<boolean>('permissions', 'request', { permissions: request?.permissions ?? [], origins: origins ?? [] });
          if (granted) request?.permissions?.forEach((name) => heldByLilo.add(name));
          return granted;
        };
        if (notRequired(request, declared()).length > 0) return promptedByLilo();
        for (;;) {
          const asked = { ...request, ...(origins && { origins }) };
          try {
            return asksForSomething(asked) ? await original.call(this, asked) : true;
          } catch (error) {
            const message = String((error as Error)?.message);
            if (unknownPermission.test(message)) return promptedByLilo();
            const origin = invalidPattern.exec(message)?.[1];
            if (!origin || !origins?.includes(origin)) throw error;
            if (!isDeclared(origin)) return false;
            origins = origins.filter((pattern) => pattern !== origin);
          }
        }
      }, callback);
    },
    remove: (original) => function (this: unknown, request: Permissions, callback?: (removed: boolean) => void) {
      return callbackify(async () => {
        // Removing it from WebKit would cut Lilo's channel.
        const forLilo = notRequired(request, declared());
        const { result, unknown } = await withoutUnknownPermissions(withoutNames(request, forLilo), (known) =>
          asksForSomething(known) ? original.call(this, known) : Promise.resolve(false));
        if (unknown.some((name) => declared().has(name))) throw new Error('You cannot remove required permissions.');
        const optional = [...forLilo, ...unknown.filter((name) => request?.permissions?.includes(name))];
        if (optional.length === 0) return result;
        await gapCall('permissions', 'remove', { permissions: optional });
        optional.forEach((name) => heldByLilo.delete(name));
        return true;
      }, callback);
    },
    getAll: (original) => function (this: unknown, callback?: (permissions: Permissions) => void) {
      return callbackify(async () => {
        const all: Permissions = await original.call(this);
        const fromWebKit = new Set(all.permissions ?? []);
        // Asked only when an optional permission may be Lilo's to grant.
        const held = declaredOptional().some((name) => !fromWebKit.has(name) || grantedForLilo.has(name)) ? await readHeldByLilo() : declared();
        const permissions = [...new Set([...fromWebKit, ...held])];
        return { ...all, permissions: permissions.filter((name) => !grantedForLilo.has(name) || held.has(name)) };
      }, callback);
    },
  };
}

/** Each WebKit event's listeners, for Chrome's hasListeners, which WebKit's events lack. */
const eventListeners = new WeakMap<object, Set<unknown>>();
/** A page's WebKit events with listeners, which its window.close() removes; null once closed, none in a worker. */
let pageEvents: Set<object> | null | undefined;

export function trackPageListeners(page: boolean): void {
  pageEvents = page ? new Set() : undefined;
}

export function removePageListeners(): void {
  for (const event of pageEvents ?? []) {
    for (const listener of [...eventListeners.get(event) ?? []]) (event as any).removeListener(listener);
  }
  pageEvents = null;
}

/**
 * Runs `add` with `filter`, and again without each resource type or URL pattern WebKit rejects as unknown (and never
 * reports); a filter left empty matches nothing, so nothing is added.
 */
export function addLeniently(filter: any, add: (filter: any) => unknown): unknown {
  for (;;) {
    try {
      return add(filter);
    } catch (error) {
      const message = String((error as Error)?.message);
      const type = unknownResourceType.exec(message)?.[1];
      const pattern = invalidMatchPattern.exec(message)?.[1];
      if (type && filter?.types?.includes(type)) {
        filter = { ...filter, types: filter.types.filter((t: string) => t !== type) };
        if (filter.types.length === 0) return undefined;
      } else if (pattern && filter?.urls?.includes(pattern)) {
        filter = { ...filter, urls: filter.urls.filter((url: string) => url !== pattern) };
        if (filter.urls.length === 0) return undefined;
      } else {
        throw error;
      }
    }
  }
}

/** Adds a listener leniently, or through its event's stand-in. A non-function listener is ignored, as in Chrome. */
export const chromeEvent: NamespaceCompat = {
  add: {
    hasListeners(this: object) { return eventStandIns.get(this)?.hasListeners() ?? (eventListeners.get(this)?.size ?? 0) > 0; },
  },
  patch: {
    addListener: (original) => function (this: any, ...args: any[]) {
      if (typeof args[0] !== 'function') return undefined;
      const standIn = eventStandIns.get(this);
      if (standIn) return (standIn.addListener as (...a: unknown[]) => void)(...args);
      if (pageEvents === null) return undefined;
      return addLeniently(args[1], (filter) => {
        const result = original.apply(this, args[1] === filter ? args : [args[0], filter, ...args.slice(2)]);
        let listeners = eventListeners.get(this);
        if (!listeners) eventListeners.set(this, (listeners = new Set()));
        listeners.add(args[0]);
        pageEvents?.add(this);
        return result;
      });
    },
    removeListener: (original) => function (this: any, listener: any) {
      if (typeof listener !== 'function') return undefined;
      const standIn = eventStandIns.get(this);
      if (standIn) return standIn.removeListener(listener);
      eventListeners.get(this)?.delete(listener);
      return original.call(this, listener);
    },
    hasListener: (original) => function (this: any, listener: any) {
      if (typeof listener !== 'function') return false;
      const standIn = eventStandIns.get(this);
      return standIn ? standIn.hasListener(listener) : original.call(this, listener);
    },
  },
};

/** Chrome still takes the MV2 action contexts, as the action's; WebKit rejects them. */
const actionContexts = new Set(['browser_action', 'page_action']);
const withActionContexts = (properties: any) => (Array.isArray(properties?.contexts) && properties.contexts.some((c: string) => actionContexts.has(c))
  ? { ...properties, contexts: [...new Set(properties.contexts.map((c: string) => (actionContexts.has(c) ? 'action' : c)))] }
  : properties);

const invalidMenuPattern = /The '(documentUrlPatterns|targetUrlPatterns)' value is invalid, because '(.*)' is not a valid pattern\./;
const missingMenuTitle = /missing required keys: 'title'|The 'title' value is invalid, because it must not be empty/;
const noMenuTitle = 'All menu items except for separators must have a title';
const ancestorMenuParent = /Parent menu item cannot be itself or another ancestor/;
// No extension id has a "v", so no document or link matches it.
const matchesNothing = 'chrome-extension://invalid/*';

/**
 * MV2 action contexts count as the action's, a null `parentId` as none, and URL patterns WebKit rejects are dropped;
 * a list left empty matches nothing rather than everything.
 */
function withChromeMenuProperties(call: (properties: any) => unknown, properties: any): unknown {
  properties = withActionContexts(properties);
  if (properties?.parentId === null) {
    properties = { ...properties };
    delete properties.parentId;
  }
  for (;;) {
    try {
      return call(properties);
    } catch (error) {
      const [, key, pattern] = invalidMenuPattern.exec(String((error as Error)?.message)) ?? [];
      if (!key || pattern === matchesNothing || !properties?.[key]?.includes?.(pattern)) throw error;
      const patterns = properties[key].filter((p: string) => p !== pattern);
      properties = { ...properties, [key]: patterns.length > 0 ? patterns : [matchesNothing] };
    }
  }
}

export const contextMenusPatches: Record<string, Patch> = {
  create: (original) => function (this: unknown, properties: any, ...rest: unknown[]) {
    try {
      return withChromeMenuProperties((chromeProperties) => original.call(this, chromeProperties, ...rest), properties);
    } catch (error) {
      if (!missingMenuTitle.test(String((error as Error)?.message))) throw error;
      // Chrome returns the id, creates no item, and reports it as runtime.lastError.
      const callback = rest[0] as (() => void) | undefined;
      if (typeof callback === 'function') callbackify(() => Promise.reject(new Error(noMenuTitle)), callback);
      else console.error(`Unchecked runtime.lastError: ${noMenuTitle}`);
      return properties?.id;
    }
  },
  update: (original) => function (this: unknown, id: unknown, properties: any, callback?: () => void) {
    const update = (changes: unknown) => withChromeMenuProperties((chromeProperties) => original.call(this, id, chromeProperties), changes);
    const updated = update(properties);
    return callbackify(() => Promise.resolve(updated).catch((error) => {
      // WebKit refuses any ancestor as the new parent, the current one included; Chrome only a cycle.
      if (!ancestorMenuParent.test(String(error?.message)) || properties.parentId === id) throw error;
      const changes = { ...properties };
      delete changes.parentId;
      return update(changes);
    }), callback);
  },
};

/**
 * Chrome's alarms.create returns a promise or takes a trailing callback; WebKit's returns nothing, and
 * takes the callback for the alarm info and rejects it.
 */
export const alarmsPatches: Record<string, Patch> = {
  create: (original) => function (this: unknown, ...args: unknown[]) {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() as () => void : undefined;
    return callbackify(() => Promise.resolve(original.apply(this, args)), callback);
  },
};

/** Chrome reads a null tabId as none; WebKit rejects it. */
const nullTabIdAsNone: Patch = (original) => function (this: unknown, details: any, ...rest: unknown[]) {
  return original.call(this, details?.tabId === null ? { ...details, tabId: undefined } : details, ...rest);
};

/**
 * Chrome's setBadgeText takes no text: a tab's badge then shows the global text again, the global one none. WebKit
 * requires it, and keeps no tab's text apart from the global one.
 */
const badgeTextOptional: Patch = (original, self) => function (this: unknown, details: any, ...rest: unknown[]) {
  if (details === null || typeof details !== 'object' || typeof details.text === 'string') return original.call(this, details, ...rest);
  const target = self(this) as any;
  const callback = typeof rest.at(-1) === 'function' ? rest.pop() as () => void : undefined;
  const tabId = details.tabId ?? undefined;
  return callbackify(async () => {
    const text = tabId === undefined ? '' : await target.getBadgeText({});
    return original.call(target, { ...details, tabId, text: text ?? '' });
  }, callback);
};

export const actionPatches: Record<string, Patch> = {
  ...Object.fromEntries([
    'setIcon', 'setTitle', 'getTitle', 'setPopup', 'getPopup', 'getBadgeText',
    'setBadgeBackgroundColor', 'getBadgeBackgroundColor', 'setBadgeTextColor', 'getBadgeTextColor',
  ].map((name) => [name, nullTabIdAsNone])),
  setBadgeText: (original, self) => badgeTextOptional(nullTabIdAsNone(original, self), self),
};

/** Chrome's getMessage answers whatever its `this`; WebKit's returns undefined off its namespace. */
export const i18nPatches: Record<string, Patch> = {
  getMessage: (original, self) => function (this: unknown, ...args: unknown[]) {
    return original.apply(self(this), args);
  },
};

/** The manifest as the extension wrote it (chromeManifest). */
export const runtimePatches: Record<string, Patch> = {
  getManifest: (original, self) => function (this: unknown, ...args: unknown[]) {
    return chromeManifest(original.apply(self(this), args));
  },
};

/** The content script registrations WebKit has not answered yet. */
const registering = new Set<Promise<unknown>>();

/**
 * Settles once no registration is in flight: Chrome answers them before the event that started the
 * worker, WebKit later (Tactiq's onInstalled unregisters what its startup is still registering).
 */
export async function registrationsSettled(): Promise<void> {
  while (registering.size) {
    await Promise.allSettled(registering);
    // A task turn lets the extension's code awaiting that answer make its next call (unregister, then register).
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}


/** `js` led by the compat, except in the MAIN world, where it would leak into the page. */
const withContentCompat = (js: string[], world: unknown) => {
  const own = js.filter((file) => file !== contentCompat);
  return world === 'MAIN' ? own : [contentCompat, ...own];
};

/** Each registration's scripts get the compat, as the manifest's do; `prepare` may need the current registrations. */
const registration = (prepare: (scripts: any, namespace: any) => unknown = (scripts) => scripts): Patch => (original, self) => function (this: unknown, ...args: any[]) {
  const last = args.length - 1;
  const callback = typeof args[last] === 'function' ? args.pop() : undefined;
  const namespace = self(this);
  const prepared = args.length ? prepare(args[0], namespace) : undefined;
  const result: Promise<unknown> = prepared instanceof Promise
    ? prepared.then((scripts) => original.call(namespace, scripts, ...args.slice(1)))
    : original.apply(namespace, args.length ? [prepared, ...args.slice(1)] : args);
  registering.add(result);
  result.then(() => registering.delete(result), () => registering.delete(result));
  return callbackify(() => result, callback);
};

const registeredWithCompat = (scripts: any) => (Array.isArray(scripts)
  ? scripts.map((script) => (Array.isArray(script?.js) && script.js.length ? { ...script, js: withContentCompat(script.js, script.world) } : script))
  : scripts);

/** An update changing `js` or `world` alone takes the other from the registration. */
function updatedWithCompat(scripts: any, namespace: any): unknown {
  if (!Array.isArray(scripts)) return scripts;
  const update = (registered: any[]) => scripts.map((script) => {
    const current = registered.find((r) => r?.id === script?.id);
    const js = script?.js ?? current?.js;
    return Array.isArray(js) && js.length ? { ...script, js: withContentCompat(js, script.world ?? current?.world) } : script;
  });
  const partial = scripts.filter((script) => (script?.js === undefined) !== (script?.world === undefined));
  return partial.length
    ? Promise.resolve(namespace.getRegisteredContentScripts({ ids: partial.map((script) => script.id) })).then(update, () => update([]))
    : update([]);
}

const noMatches = /The 'matches' value is invalid, because it must specify at least one match pattern for script with ID '(.*)'\./;

/** WebKit's own executeScript, for Lilo's injections. */
function injected(namespace: any, injection: unknown): Promise<any[] | undefined> {
  const executeScript = namespace.executeScript;
  return (executeScript.__liloUnwrapped ?? executeScript).call(namespace, injection);
}

// WebKit scripts the extension's own pages, Chrome refuses them: a popup shown in a tab that scripts the
// active tab (Jetwriter) reaches itself. `results` hold each target document's URL.
async function refuseOwnPages(results: any[] | undefined): Promise<void> {
  const chrome = bridgeChrome();
  const own = chrome.runtime.getURL('');
  const url: string | undefined = results?.map((result) => result?.result).find((href) => typeof href === 'string' && href.startsWith(own));
  if (!url) return;
  // Chrome names the page only to an extension that may read tab urls.
  throw new Error(await chrome.permissions.contains({ permissions: ['tabs'] })
    ? `Cannot access contents of url "${url}". Extension manifest must request permission to access this host.`
    : 'Cannot access contents of the page. Extension manifest must request permission to access the respective host.');
}

/**
 * Each target document's URL, once it has loaded unless `immediately`: Chrome injects into a document once it has
 * loaded unless asked to inject immediately, WebKit always at once. A target Lilo cannot reach answers nothing.
 */
const targetURLs = (namespace: any, target: unknown, immediately: boolean) => injected(namespace, {
  target,
  injectImmediately: true,
  // Runs in the target document, named as an argument: the worker has none, which its prelude must never name.
  func: (name: string, now: boolean) => {
    const page = (globalThis as any)[name];
    return now || page.readyState !== 'loading'
      ? page.URL
      : new Promise((resolve) => page.addEventListener('DOMContentLoaded', () => resolve(page.URL), { once: true }));
  },
  args: ['document', immediately],
}).catch(() => undefined);

/**
 * Runs in each target frame, as a style sheet the document adopts, keyed by its text for removeCSS. The
 * extension's own page is left alone and answers its URL.
 */
function styleFrame(name: string, ownPages: string, css: string, remove: boolean): string | undefined {
  const page = (globalThis as any)[name];
  if (page.URL.startsWith(ownPages)) return page.URL;
  const key = Symbol.for('lilo.insertedCSS');
  const inserted: Map<string, CSSStyleSheet[]> = (globalThis as any)[key] ??= new Map();
  const sheets = inserted.get(css) ?? [];
  if (remove) {
    const sheet = sheets.pop();
    if (sheet) page.adoptedStyleSheets = page.adoptedStyleSheets.filter((adopted: CSSStyleSheet) => adopted !== sheet);
  } else {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(css);
    page.adoptedStyleSheets = [...page.adoptedStyleSheets, sheet];
    sheets.push(sheet);
  }
  inserted.set(css, sheets);
  return undefined;
}

/** WebKit applies CSS given frame ids to the main frame only: Lilo styles those frames itself. */
const styleSheet = (remove: boolean): Patch => (original, self) => function (this: unknown, injection: any, callback?: () => void) {
  const namespace = self(this);
  return callbackify(async () => {
    const chrome = bridgeChrome();
    if (!injection?.target?.frameIds?.some?.((id: unknown) => id !== 0)) {
      await refuseOwnPages(injection?.target === undefined ? undefined : await targetURLs(namespace, injection.target, true));
      return original.call(namespace, injection);
    }
    const css = typeof injection.css === 'string' ? injection.css : (await Promise.all((injection.files ?? []).map(async (file: string) => {
      const response = await fetch(chrome.runtime.getURL(file)).catch(() => undefined);
      if (!response?.ok) throw new Error(`Could not load file: '${file}'.`);
      return response.text();
    }))).join('\n');
    await refuseOwnPages(await injected(namespace, {
      target: injection.target, injectImmediately: true, func: styleFrame, args: ['document', chrome.runtime.getURL(''), css, remove],
    }));
    return undefined;
  }, callback);
};

export const scriptingPatches: Record<string, Patch> = {
  executeScript: (original, self) => function (this: unknown, injection: any, callback?: (results: unknown) => void) {
    const namespace = self(this);
    return callbackify(async () => {
      if (injection?.target !== undefined) await refuseOwnPages(await targetURLs(namespace, injection.target, injection.injectImmediately === true));
      const files = Array.isArray(injection?.files) && injection.files.length > 0;
      return original.call(namespace, files ? { ...injection, files: withContentCompat(injection.files, injection.world) } : injection);
    }, callback);
  },
  insertCSS: styleSheet(false),
  removeCSS: styleSheet(true),
  registerContentScripts: (original, self) => {
    const register = registration(registeredWithCompat)(original, self);
    return function (this: unknown, scripts: any, ...rest: unknown[]) {
      try {
        return register.call(this, scripts, ...rest);
      } catch (error) {
        const id = noMatches.exec(String((error as Error)?.message))?.[1];
        const script = id === undefined ? undefined : scripts?.find?.((s: any) => s?.id === id);
        if (!script) throw error;
        // Chrome rejects the call where WebKit throws.
        const message = script.matches === undefined ? `Script with ID '${id}' must specify 'matches'.` : `Script with ID '${id}' must specify at least one match.`;
        return callbackify(() => Promise.reject(new Error(message)), rest[0] as (() => void) | undefined);
      }
    };
  },
  updateContentScripts: registration(updatedWithCompat),
  unregisterContentScripts: registration(),
  getRegisteredContentScripts: (original, self) => function (this: unknown, ...args: any[]) {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : undefined;
    return callbackify(async () => {
      const scripts = await original.apply(self(this), args);
      return Array.isArray(scripts) ? scripts.map(withoutContentCompat) : scripts;
    }, callback);
  },
};

/**
 * WebKit sets no runtime.lastError when a native port's host is missing or fails, so Lilo sends Chrome's on ports
 * this marks. connectNative is an own property of WebKit's runtime, and wrapping `browser` breaks WebKit.
 */
export function nativeMessagingAsChrome(runtime: any): Record<PropertyKey, unknown> {
  return {
    connectNative(application: string) {
      if (application === CHANNEL_HOST) return runtime.connectNative(application);
      // `?` never appears in a host name: Lilo strips the mark and knows this port is served here.
      const port = runtime.connectNative(`${application}?lilo`);
      let error: string | undefined;
      let disconnected = false;
      const served = {
        name: port.name,
        sender: port.sender,
        onMessage: new ChromeEvent<[unknown, unknown]>(),
        onDisconnect: new ChromeEvent<[unknown]>(),
        postMessage: (message: unknown) => {
          if (disconnected) throw new Error('Attempting to use a disconnected port object');
          port.postMessage(message);
        },
        disconnect: () => {
          disconnected = true;
          port.disconnect();
        },
      };
      port.onMessage.addListener((message: any) => {
        if (typeof message?.liloNativePortError === 'string') error = message.liloNativePortError;
        else served.onMessage.dispatch(message, served);
      });
      port.onDisconnect.addListener(() => {
        disconnected = true;
        if (error === undefined) served.onDisconnect.dispatch(served);
        else withLastError(error, () => served.onDisconnect.dispatch(served));
      });
      port.postMessage({ liloNativePortOpened: true });
      return served;
    },
  };
}
