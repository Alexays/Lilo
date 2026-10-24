// WebKit never exposes its tab and window ids to Swift, so grouping calls send each tab's window position and index,
// which native maps back to a Lilo tab. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';
import type { NamespaceCompat } from '../shared/chrome-compat.ts';

export const TAB_GROUP_ID_NONE = -1;

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

/** The ids of chrome.windows.getAll, in its order; empty when unknown. */
async function windowIdOrder(): Promise<number[]> {
  try {
    return ((await bridgeChrome()?.windows?.getAll?.()) ?? []).map((w: any) => w.id);
  } catch {
    return [];
  }
}

/** Each tab's window position (in chrome.windows.getAll order) and index, or -1 when unknown. */
export async function toPositions(
  tabList: { index: number; windowId: number }[],
  windowIds: Promise<number[]> = windowIdOrder(),
): Promise<TabPosition[]> {
  const order = await windowIds;
  return tabList.map((t) => ({ windowPosition: order.indexOf(t.windowId), index: t.index }));
}

/**
 * Resolve integer tab ids to positions, the bridge to Lilo's tab identity. Unknown ids drop. Every lookup runs at
 * once: the tabs and the window order come back in one round trip whatever the number of ids.
 */
export async function tabPositions(tabIds: number[]): Promise<TabPosition[]> {
  const tabs = bridgeChrome()?.tabs;
  if (!tabs?.get || tabIds.length === 0) return [];
  // Skips the groupId lookup tabGroups adds to tabs.get.
  const get = tabs.get.__liloUnwrapped ?? tabs.get;
  const windowIds = windowIdOrder();
  const found = await Promise.all(tabIds.map(async (id) => {
    try {
      return await get.call(tabs, id);
    } catch {
      return undefined;
    }
  }));
  return toPositions(found.filter((t) => typeof t?.index === 'number'), windowIds);
}

/** The `{windowPosition, index}` native resolves a tab id by. */
export async function tabPosition(tabId: unknown) {
  const [position] = typeof tabId === 'number' ? await tabPositions([tabId]) : [];
  if (!position || position.windowPosition < 0) throw new Error('Invalid tab specified.');
  return position;
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

/** chrome.tabs over Lilo folders: `group` and `ungroup`, absent in WebKit. */
export const tabsWithGroups: NamespaceCompat = {
  replace: { group: liloGroup, ungroup: liloUngroup },
};
