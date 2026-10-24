// WebKit never exposes its tab and window ids to Swift, so grouping calls send each tab's window position and index,
// which native maps back to a Lilo tab. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';
import type { NamespaceCompat, Patch } from '../shared/chrome-compat.ts';

const TAB_GROUP_ID_NONE = -1;

interface TabGroup {
  id: number;
  title: string;
  color: string;
  collapsed: boolean;
  windowId: number;
}

/** The calling extension's manifest permissions. Chrome exposes each gap namespace only when declared. */
export function manifestPermissions(chromeObj: any): Set<string> {
  try {
    const perms = chromeObj?.runtime?.getManifest?.()?.permissions;
    return new Set(Array.isArray(perms) ? perms : []);
  } catch {
    return new Set();
  }
}

/** windowId is the one identifier only WebKit knows; stamp it from the live current window. */
async function currentWindowId(): Promise<number> {
  try {
    const w = await bridgeChrome()?.windows?.getCurrent?.();
    return typeof w?.id === 'number' ? w.id : -1;
  } catch {
    return -1;
  }
}

function stampWindowId(group: TabGroup, windowId: number): TabGroup {
  if (group) group.windowId = windowId;
  return group;
}

interface TabPosition {
  windowPosition: number;
  index: number;
}

/** Each tab's window position (in chrome.windows.getAll order) and index, or -1 when unknown. */
export async function toPositions(tabList: { index: number; windowId: number }[]): Promise<TabPosition[]> {
  let windowIds: number[] = [];
  try {
    windowIds = ((await bridgeChrome()?.windows?.getAll?.()) ?? []).map((w: any) => w.id);
  } catch {
    /* positions stay unknown */
  }
  return tabList.map((t) => ({ windowPosition: windowIds.indexOf(t.windowId), index: t.index }));
}

/** Resolve integer tab ids to positions, the bridge to Lilo's tab identity. Unknown ids drop. */
export async function tabPositions(tabIds: number[]): Promise<TabPosition[]> {
  const tabs = bridgeChrome()?.tabs;
  if (!tabs?.get) return [];
  const found: { index: number; windowId: number }[] = [];
  for (const id of tabIds) {
    try {
      const t = await tabs.get(id);
      if (typeof t?.index === 'number') found.push(t);
    } catch {
      /* unknown tab: skip */
    }
  }
  return toPositions(found);
}

/**
 * chrome.tabs.discard, which WebKit lacks: Lilo drops the tab's page and keeps the tab. A tab on screen
 * is never discarded, and Lilo always needs the tab named.
 */
export function discardTab(tabId?: number | ((tab: unknown) => void), callback?: (tab: unknown) => void) {
  const [id, cb] = typeof tabId === 'function' ? [undefined, tabId] : [tabId, callback];
  return callbackify(async () => {
    if (typeof id !== 'number') throw new Error('Lilo needs the id of the tab to discard');
    await gapCall<null>('tabs', 'discard', { tabs: await tabPositions([id]) });
    return bridgeChrome().tabs.get(id);
  }, cb);
}

function asIdArray(raw: unknown): number[] {
  if (Array.isArray(raw)) return raw.filter((n) => typeof n === 'number') as number[];
  return typeof raw === 'number' ? [raw] : [];
}

export const tabGroupsAugmentation = {
  TAB_GROUP_ID_NONE,
  Color: {
    GREY: 'grey',
    BLUE: 'blue',
    RED: 'red',
    YELLOW: 'yellow',
    GREEN: 'green',
    PINK: 'pink',
    PURPLE: 'purple',
    CYAN: 'cyan',
    ORANGE: 'orange',
  },

  query(queryInfo: any = {}, callback?: (groups: TabGroup[]) => void) {
    return callbackify(async () => {
      const res = await gapCall<{ groups: TabGroup[] }>('tabGroups', 'query', queryInfo ?? {});
      const wid = await currentWindowId();
      return (res?.groups ?? []).map((g) => stampWindowId(g, wid));
    }, callback);
  },

  get(groupId: number, callback?: (group: TabGroup) => void) {
    return callbackify(async () => {
      const res = await gapCall<{ group: TabGroup }>('tabGroups', 'get', { groupId });
      return stampWindowId(res?.group, await currentWindowId());
    }, callback);
  },

  update(groupId: number, updateProperties: any = {}, callback?: (group: TabGroup) => void) {
    return callbackify(async () => {
      const res = await gapCall<{ group: TabGroup }>('tabGroups', 'update', { groupId, ...updateProperties });
      return stampWindowId(res?.group, await currentWindowId());
    }, callback);
  },

  move(groupId: number, moveProperties: any = {}, callback?: (group: TabGroup) => void) {
    return callbackify(async () => {
      const res = await gapCall<{ group: TabGroup }>('tabGroups', 'move', { groupId, ...moveProperties });
      return stampWindowId(res?.group, await currentWindowId());
    }, callback);
  },

  // Native pushes onCreated/onUpdated/onRemoved with windowId -1 (only WebKit knows it); onMoved
  // has no native source and stays inert, so feature detection and addListener() calls don't throw.
  ...createGapEventsFromNames('tabGroups', ['onCreated', 'onUpdated', 'onMoved', 'onRemoved']),
};

function liloGroup(options: any = {}, callback?: (groupId: number) => void) {
  return callbackify(async () => {
    const res = await gapCall<{ groupId: number }>('tabs', 'group', {
      tabs: await tabPositions(asIdArray(options?.tabIds)),
      groupId: options?.groupId,
      windowId: options?.createProperties?.windowId,
    });
    return res?.groupId ?? TAB_GROUP_ID_NONE;
  }, callback);
}

function liloUngroup(rawIds: any, callback?: () => void) {
  return callbackify(async () => {
    await gapCall('tabs', 'ungroup', { tabs: await tabPositions(asIdArray(rawIds)) });
    return undefined as unknown as void;
  }, callback);
}

/**
 * tabs.query / tabs.get with a `groupId` on every returned tab, in both forms. WebKit ignores the
 * `groupId` query key, so query filters on it here.
 */
const withGroupIds = (method: 'query' | 'get'): Patch => (original, self) => function (this: unknown, ...args: any[]) {
  const callback = typeof args[args.length - 1] === 'function' ? args.pop() : undefined;
  const groupId = method === 'query' ? args[0]?.groupId : undefined;
  if (groupId !== undefined) {
    const { groupId: _omitted, ...rest } = args[0];
    args[0] = rest;
  }
  return callbackify(async () => {
    const result = await original.apply(self(this), args);
    await injectGroupIds(Array.isArray(result) ? result : [result]);
    return typeof groupId === 'number' ? result.filter((t: any) => t?.groupId === groupId) : result;
  }, callback);
};

/** chrome.tabs over Lilo folders: `group`/`ungroup`, absent in WebKit, and each tab's `groupId`. */
export const tabsWithGroups: NamespaceCompat = {
  replace: { group: liloGroup, ungroup: liloUngroup },
  patch: { query: withGroupIds('query'), get: withGroupIds('get') },
};

async function injectGroupIds(tabList: any[]): Promise<void> {
  const valid = tabList.filter((t) => t && typeof t.index === 'number');
  if (valid.length === 0) return;
  try {
    const res = await gapCall<{ groupIds: number[] }>('tabs', 'resolveGroupIds', {
      tabs: await toPositions(valid),
    });
    const ids = res?.groupIds ?? [];
    valid.forEach((t, i) => {
      t.groupId = typeof ids[i] === 'number' ? ids[i] : TAB_GROUP_ID_NONE;
    });
  } catch {
    valid.forEach((t) => {
      if (typeof t.groupId !== 'number') t.groupId = TAB_GROUP_ID_NONE;
    });
  }
}
