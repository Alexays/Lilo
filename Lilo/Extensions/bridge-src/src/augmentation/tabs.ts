// WebKit owns the tab and window ids: calls send each tab's window position and index, and native events carry them
// back to be resolved here from WebKit's chrome.windows/chrome.tabs. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { resolvingEvent } from '../shared/gap-event.ts';
import { WrappedEvent } from '../shared/chrome-event.ts';
import { TAB_GROUP_ID_NONE, tabPositions, toPositions, windowIdOrder } from './tabGroups.ts';
import type { Patch } from '../shared/chrome-compat.ts';

export interface TabPosition {
  windowPosition: number;
  index: number;
}

interface ZoomSettings {
  mode?: string;
  scope?: string;
  defaultZoomFactor?: number;
}

/** The WebKit window at `position` in `windows.getAll()`, the bridge from Lilo's window order. */
export async function windowAt(position: number, getInfo?: object): Promise<any> {
  const windows = await bridgeChrome().windows.getAll(getInfo);
  return windows?.[position];
}

/** The WebKit tab at a native position, or undefined when it is gone. */
export async function tabAt(position: TabPosition): Promise<any> {
  const c = bridgeChrome();
  const windowId = (await windowAt(position.windowPosition))?.id;
  if (typeof windowId !== 'number') return undefined;
  // Skips the groupId lookup tabGroups adds to tabs.query.
  const query = c.tabs.query.__liloUnwrapped ?? c.tabs.query;
  const [tab] = await query.call(c.tabs, { windowId, index: position.index });
  return tab;
}

/** The position of tab `tabId`, failing with Chrome's error for an unknown id. */
async function positionOf(tabId: number): Promise<TabPosition> {
  const [position] = await tabPositions([tabId]);
  if (!position || position.windowPosition < 0) throw new Error(`No tab with id: ${tabId}.`);
  return position;
}

/** Chrome's default for an omitted tab id: the active tab of the current window. */
async function positionOfTabOrActive(tabId?: number): Promise<TabPosition> {
  if (typeof tabId === 'number') return positionOf(tabId);
  const c = bridgeChrome();
  const query = c.tabs.query.__liloUnwrapped ?? c.tabs.query;
  const [active] = await query.call(c.tabs, { active: true, currentWindow: true });
  if (typeof active?.id !== 'number') throw new Error('No active tab');
  return positionOf(active.id);
}

/** Lilo has no multi-tab selection: highlighting makes the first tab active, as Chrome does. */
function highlight(info: { windowId?: number; tabs: number | number[] }, callback?: (window: any) => void) {
  return callbackify(async () => {
    const c = bridgeChrome();
    const windowId = info?.windowId ?? (await c.windows.getCurrent())?.id;
    const indices = Array.isArray(info?.tabs) ? info.tabs : [info?.tabs];
    if (indices.length === 0) throw new Error('No highlighted tab');
    let tabs: any[];
    try {
      tabs = (await c.windows.get(windowId, { populate: true })).tabs ?? [];
    } catch {
      throw new Error(`No window with id: ${windowId}.`);
    }
    for (const index of indices) {
      if (!tabs.some((tab) => tab.index === index)) throw new Error(`No tab at index: ${index}.`);
    }
    await c.tabs.update(tabs.find((tab) => tab.index === indices[0]).id, { active: true });
    return c.windows.get(windowId, { populate: true });
  }, callback);
}

function getZoomSettings(tabId?: number | ((settings: ZoomSettings) => void), callback?: (settings: ZoomSettings) => void) {
  const [id, cb] = typeof tabId === 'function' ? [undefined, tabId] : [tabId, callback];
  return callbackify(async () => gapCall<ZoomSettings>('tabs', 'getZoomSettings', { tab: await positionOfTabOrActive(id) }), cb);
}

function setZoomSettings(tabId: number | ZoomSettings | undefined, settings?: ZoomSettings | (() => void), callback?: () => void) {
  const [id, zoomSettings, cb] = typeof tabId === 'object'
    ? [undefined, tabId, settings as (() => void) | undefined]
    : [tabId, settings as ZoomSettings, callback];
  return callbackify(async () => {
    if (zoomSettings?.scope === 'per-origin' && zoomSettings.mode !== undefined && zoomSettings.mode !== 'automatic') {
      throw new Error('Can only set scope to "per-origin" in "automatic" mode.');
    }
    await gapCall<null>('tabs', 'setZoomSettings', { tab: await positionOfTabOrActive(id), mode: zoomSettings?.mode, scope: zoomSettings?.scope });
  }, cb);
}

function createSplit(tabIds: [number, number], callback?: (splitViewId: number) => void) {
  return callbackify(async () => {
    if (tabIds?.[0] === tabIds?.[1]) throw new Error('Cannot create a split view with duplicate tab IDs.');
    const tabs = await Promise.all([positionOf(tabIds[0]), positionOf(tabIds[1])]);
    return gapCall<number>('tabs', 'createSplit', { tabs, tabIds });
  }, callback);
}

function unsplit(splitViewId: number, callback?: () => void) {
  return callbackify(() => gapCall<void>('tabs', 'unsplit', { splitViewId }), callback);
}

interface ZoomChange extends TabPosition {
  oldZoomFactor: number;
  newZoomFactor: number;
  zoomSettings: ZoomSettings;
}

const onZoomChange = resolvingEvent<ZoomChange>('tabs', 'onZoomChange', async (raw) => {
  const tab = await tabAt(raw);
  if (typeof tab?.id !== 'number') return null;
  const { oldZoomFactor, newZoomFactor, zoomSettings } = raw;
  return [{ tabId: tab.id, oldZoomFactor, newZoomFactor, zoomSettings }];
});

export const onBoundsChanged = resolvingEvent<{ windowPosition: number }>('windows', 'onBoundsChanged', async (raw) => {
  const found = await windowAt(raw.windowPosition);
  return found ? [found] : null;
});

export const tabsAdditions = { highlight, getZoomSettings, setZoomSettings, createSplit, unsplit, onZoomChange };

/** `tab` without the url and title WebKit reports as "" for a tab the extension may not access, as Chrome. */
function withoutWithheld(tab: any): any {
  if (tab?.url === '') {
    delete tab.url;
    delete tab.title;
  }
  return tab;
}

/** What WebKit's Tab objects lack, from Lilo; null for a tab Lilo does not hold. */
interface TabDetails {
  groupId: number;
  discarded: boolean;
  frozen: boolean;
  lastAccessed?: number;
  url?: string;
  title?: string;
}

/**
 * `tab` with Chrome's fields WebKit's lacks. Without `details` (a tab event, which Lilo cannot answer in step with WebKit's
 * delivery), each takes Chrome's value for a loaded tab outside any group.
 */
function asChromeTab(tab: any, details?: TabDetails | null): any {
  if (tab === null || typeof tab !== 'object') return tab;
  tab.groupId = details?.groupId ?? TAB_GROUP_ID_NONE;
  tab.discarded = details?.discarded ?? false;
  tab.frozen = details?.frozen ?? false;
  tab.autoDiscardable = true;
  if (details?.lastAccessed !== undefined) tab.lastAccessed = details.lastAccessed;
  if (tab.discarded) tab.status = 'unloaded';
  return tab;
}

/**
 * The tabs of a result made Chrome's in one call to Lilo. With `tabs`, Chrome shows every tab's url and title, where WebKit
 * shows only those of the hosts the extension may access: the same call reads the ones WebKit left empty, an empty tab
 * reading as Chrome's new tab page. Without it, the empty ones are left out, as in Chrome.
 */
async function completeTabs(tabs: any[], withheldURLs: boolean, windowIds?: Promise<number[]>): Promise<void> {
  const listed = tabs.filter((tab) => typeof tab?.index === 'number');
  if (listed.length === 0) return;
  const reveal = withheldURLs ? [] : listed.flatMap((tab, i) => (tab.url === '' ? [i] : []));
  const details = await gapCall<Array<TabDetails | null>>('tabs', 'details', { tabs: await toPositions(listed, windowIds), reveal }).catch(() => []);
  listed.forEach((tab, i) => {
    const found = details?.[i];
    if (found?.url) Object.assign(tab, { url: found.url, title: found.title });
    asChromeTab(tab, found);
    if (withheldURLs) withoutWithheld(tab);
  });
}

/**
 * WebKit's method, its tabs completed. `filtersGroups`: `tabs.query`, whose `groupId` key WebKit ignores, so Lilo filters on it.
 * `returnsTabs`: a tabs method, whose window order is read alongside the call rather than after it.
 */
const completing = (withheldURLs: boolean, returnsTabs: boolean, filtersGroups = false): Patch => (original, self) => function (this: unknown, ...args: any[]) {
  const callback = typeof args[args.length - 1] === 'function' ? args.pop() : undefined;
  const groupId = filtersGroups ? args[0]?.groupId : undefined;
  if (groupId !== undefined) {
    const { groupId: _omitted, ...rest } = args[0];
    args[0] = rest;
  }
  return callbackify(async () => {
    const windowIds = returnsTabs ? windowIdOrder() : undefined;
    const result = await original.apply(self(this), args);
    // A window lists its tabs; anything else is a tab.
    await completeTabs((Array.isArray(result) ? result : [result]).flatMap((item) => item?.tabs ?? [item]), withheldURLs, windowIds);
    return typeof groupId === 'number' ? result.filter((tab: any) => tab.groupId === groupId) : result;
  }, callback);
};

const tabMethods = ['get', 'getCurrent', 'create', 'update', 'duplicate', 'move'];
const windowMethods = ['get', 'getAll', 'getCurrent', 'getLastFocused', 'create'];

export function tabPatches(withheldURLs: boolean): Record<string, Patch> {
  return { ...Object.fromEntries(tabMethods.map((name) => [name, completing(withheldURLs, true)])), query: completing(withheldURLs, true, true) };
}

export function windowPatches(withheldURLs: boolean): Record<string, Patch> {
  return Object.fromEntries(windowMethods.map((name) => [name, completing(withheldURLs, false)]));
}

/** Tab events with Chrome's tab, without what the extension may not see, as Chrome, which still reports an update of nothing else. */
export function tabStandIns(withheldURLs: boolean): Record<string, WrappedEvent<any>> {
  const shown = (tab: any) => (withheldURLs ? withoutWithheld(tab) : tab);
  return {
    onCreated: new WrappedEvent<[any]>(() => bridgeChrome().tabs.onCreated, (listener) => (tab: any) => {
      // A new tab was last accessed when it was made.
      if (asChromeTab(tab) && tab.lastAccessed === undefined) tab.lastAccessed = Date.now();
      return listener(shown(tab));
    }),
    onUpdated: new WrappedEvent<[number, any, any]>(() => bridgeChrome().tabs.onUpdated, (listener) => (tabId: number, changeInfo: any, tab: any) => {
      if (withheldURLs && tab?.url === '' && changeInfo) {
        delete changeInfo.url;
        delete changeInfo.title;
      }
      return listener(tabId, changeInfo, shown(asChromeTab(tab)));
    }),
  };
}

/**
 * WebKit answers `tabs.getCurrent` in an action popup with the window's active tab, where Chrome answers undefined:
 * only a page a tab shows, or a frame in one, has a current tab. Proton Pass took its popup for a tab's page and sized
 * it to the viewport, which collapsed it.
 */
export const currentTabOfThisPage: Patch = (original, self) => function (this: unknown, callback?: (tab?: any) => void) {
  return callbackify(async () => {
    const tab = await original.call(self(this));
    const page = (globalThis as any).location?.href?.split('#')[0];
    const shown = (tab?.url || tab?.pendingUrl || '').split('#')[0];
    return (globalThis as any).top !== globalThis || shown === page ? tab : undefined;
  }, callback);
};

/**
 * WebKit rejects `chrome://` url patterns in `tabs.query`, which Chrome matches against its own pages: Lilo's one is
 * the new tab page, which `query` reports as `chrome://newtab/`. Lilo matches those patterns, WebKit the others.
 */
export const chromePageQuery: Patch = (original, self) => function (this: unknown, queryInfo: any, callback?: (tabs: any[]) => void) {
  const patterns: unknown[] = typeof queryInfo?.url === 'string' ? [queryInfo.url] : Array.isArray(queryInfo?.url) ? queryInfo.url : [];
  const chromePages = patterns.filter((pattern): pattern is string => typeof pattern === 'string' && pattern.startsWith('chrome://'));
  if (chromePages.length === 0) return original.apply(self(this), callback ? [queryInfo, callback] : [queryInfo]);
  return callbackify(async () => {
    const target = self(this);
    const others = patterns.filter((pattern) => !chromePages.includes(pattern as string));
    const { url: _url, ...rest } = queryInfo;
    const matched = new Set(others.length ? (await original.call(target, { ...rest, url: others })).map((tab: any) => tab.id) : []);
    const matchers = chromePages.map((pattern) => new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*')}$`));
    return (await original.call(target, rest)).filter((tab: any) => matched.has(tab.id) || matchers.some((matcher) => matcher.test(tab.url ?? '')));
  }, callback);
};
