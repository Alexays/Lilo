// WebKit owns the tab and window ids: calls send each one's position in WebKit's lists beside it (the ids only
// shape native's errors). SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { tabPositions } from './tabGroups.ts';
import { resolvingEvent } from '../shared/gap-event.ts';
import { tabAt, windowAt } from './tabs.ts';

const WINDOW_ID_CURRENT = -2;

interface PanelEvent {
  windowPosition: number;
  /** The tab's index in its window, for a tab-specific panel. */
  index?: number;
  path: string;
}

/** Chrome's `{windowId, tabId?, path}`; a window or tab gone by then reads as -1 or no tabId. */
async function panelInfo({ windowPosition, index, path }: PanelEvent): Promise<unknown[]> {
  const windowId = (await windowAt(windowPosition).catch(() => undefined))?.id ?? -1;
  const info: Record<string, unknown> = { windowId };
  if (typeof index === 'number' && windowId !== -1) {
    const tabId = (await tabAt({ windowPosition, index }).catch(() => undefined))?.id;
    if (typeof tabId === 'number') info.tabId = tabId;
  }
  info.path = path;
  return [info];
}

interface SidePanelOptions {
  tabId?: number;
  path?: string;
  enabled?: boolean;
}

interface Target {
  tabId?: number;
  windowId?: number;
}

/** The target's ids with their positions: `tab` is left out for an unknown tab, `windowPosition` is -1 for an unknown window. */
async function withPositions(target: Target | undefined): Promise<Record<string, unknown>> {
  const c = bridgeChrome();
  const { tabId, windowId } = target ?? {};
  const params: Record<string, unknown> = { tabId, windowId };
  if (typeof tabId === 'number') {
    const [tab] = await tabPositions([tabId]);
    if (tab && tab.windowPosition >= 0) params.tab = tab;
  }
  if (typeof windowId === 'number') {
    const windows: any[] = (await c.windows.getAll().catch(() => [])) ?? [];
    const id = windowId === WINDOW_ID_CURRENT ? (await c.windows.getCurrent().catch(() => undefined))?.id : windowId;
    params.windowPosition = windows.findIndex((w) => w.id === id);
  }
  return params;
}

export const sidePanelAugmentation = {
  setOptions(options: SidePanelOptions, callback?: () => void) {
    return callbackify(
      async () => gapCall<null>('sidePanel', 'setOptions', { ...options, ...(await withPositions({ tabId: options?.tabId })) }),
      callback,
    );
  },
  getOptions(options: { tabId?: number } = {}, callback?: (options: SidePanelOptions) => void) {
    return callbackify(
      async () => gapCall<SidePanelOptions>('sidePanel', 'getOptions', await withPositions({ tabId: options?.tabId })),
      callback,
    );
  },
  open(options: Target, callback?: () => void) {
    // Read before any await: the page's transient activation is the gesture Chrome requires.
    const userGesture = (globalThis as any).navigator?.userActivation?.isActive === true;
    return callbackify(
      async () => gapCall<null>('sidePanel', 'open', { ...(await withPositions(options)), userGesture }),
      callback,
    );
  },
  close(options: Target, callback?: () => void) {
    return callbackify(
      async () => gapCall<null>('sidePanel', 'close', await withPositions(options)),
      callback,
    );
  },
  setPanelBehavior(behavior: { openPanelOnActionClick?: boolean }, callback?: () => void) {
    return callbackify(
      () => gapCall<null>('sidePanel', 'setPanelBehavior', behavior),
      callback,
    );
  },
  getPanelBehavior(callback?: (behavior: { openPanelOnActionClick: boolean }) => void) {
    return callbackify(
      () => gapCall<{ openPanelOnActionClick: boolean }>('sidePanel', 'getPanelBehavior'),
      callback,
    );
  },
  getLayout(callback?: (layout: { side: string }) => void) {
    // Lilo always docks the side panel on the right.
    return callbackify(async () => ({ side: 'right' }), callback);
  },
  onOpened: resolvingEvent<PanelEvent>('sidePanel', 'onOpened', panelInfo),
  onClosed: resolvingEvent<PanelEvent>('sidePanel', 'onClosed', panelInfo),
};
