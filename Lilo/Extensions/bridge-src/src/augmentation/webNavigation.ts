// Native reports tabs by window position and index, as only WebKit knows the integer tab id; it is resolved here.
// onTabReplaced never fires: Lilo never swaps in a prerendered page. SW-safe: no window/document/webkit.
import { ChromeEvent, WrappedEvent } from '../shared/chrome-event.ts';
import { GapChromeEvent } from '../shared/gap-event.ts';
import { compileUrlFilters, type UrlFilter } from '../shared/url-filter.ts';
import { tabAt, type TabPosition } from './tabs.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import type { Patch } from '../shared/chrome-compat.ts';

interface SameDocumentNavigation {
  windowPosition: number;
  index: number;
  url: string;
  timeStamp: number;
  transitionQualifiers: string[];
}

type Listener = (details: any) => void;

interface CreatedNavigationTarget {
  source: TabPosition;
  tab: TabPosition;
  url: string;
  timeStamp: number;
}

function tabResolvingEvent<Raw extends { url: string }>(name: string, details: (raw: Raw) => Promise<any>): ChromeEvent<[any]> {
  const event = new GapChromeEvent<[any]>('webNavigation', name);
  const filters = new Map<Listener, ((url: URL) => boolean) | undefined>();
  const add = event.addListener.bind(event);
  const remove = event.removeListener.bind(event);
  (event as any).addListener = (listener: Listener, filter?: { url?: UrlFilter[] }) => {
    filters.set(listener, compileUrlFilters(filter?.url));
    add(listener);
  };
  event.removeListener = (listener: Listener) => {
    filters.delete(listener);
    remove(listener);
  };
  const fire = (details: any) => {
    const url = URL.canParse(details.url) ? new URL(details.url) : undefined;
    for (const [listener, matches] of [...filters]) {
      if (matches && !(url && matches(url))) continue;
      try {
        listener(details);
      } catch (err) {
        console.error(`Error in event handler: ${String(err)}`);
      }
    }
  };
  event.dispatch = (raw: Raw) => {
    if (!event.hasListeners() || !raw) return;
    details(raw).then((resolved) => { if (resolved) fire(resolved); }, () => { /* the tab closed before it resolved */ });
  };
  return event;
}

async function sameDocumentDetails(raw: SameDocumentNavigation): Promise<any> {
  const tab = await tabAt(raw);
  if (typeof tab?.id !== 'number') return null;
  return {
    tabId: tab.id,
    url: raw.url,
    processId: -1,
    frameId: 0,
    parentFrameId: -1,
    frameType: 'outermost_frame',
    documentLifecycle: 'active',
    timeStamp: raw.timeStamp,
    transitionType: 'link',
    transitionQualifiers: raw.transitionQualifiers ?? [],
  };
}

async function createdNavigationTargetDetails(raw: CreatedNavigationTarget): Promise<any> {
  const [source, tab] = await Promise.all([tabAt(raw.source), tabAt(raw.tab)]);
  if (typeof source?.id !== 'number' || typeof tab?.id !== 'number') return null;
  return { sourceTabId: source.id, sourceProcessId: -1, sourceFrameId: 0, url: raw.url, tabId: tab.id, timeStamp: raw.timeStamp };
}

/** The main frame Chrome keeps for a discarded tab, which WebKit reports as missing; null for a missing tab. */
async function discardedMainFrame(tabId: unknown): Promise<{ errorOccurred: boolean; parentFrameId: number; url?: string } | null> {
  const tabs = bridgeChrome().tabs;
  const tab = await (tabs.get.__liloUnwrapped ?? tabs.get).call(tabs, tabId).catch(() => null);
  return tab && { errorOccurred: false, parentFrameId: -1, url: tab.url };
}

// WebKit rejects where Chrome resolves: null for a missing tab or frame, and no frame for a tab with
// no document yet.
export const webNavigationPatches: Record<string, Patch> = {
  getAllFrames: (original, self) => function (this: unknown, details: any, callback?: (frames: unknown) => void) {
    return callbackify(async () => {
      try {
        return await original.call(self(this), details);
      } catch (error) {
        const message = error instanceof Error ? error.message : '';
        if (message.endsWith('Main frame not found.')) return [];
        if (!message.endsWith('Tab not found.')) throw error;
        const frame = await discardedMainFrame(details?.tabId);
        return frame && [{ ...frame, frameId: 0 }];
      }
    }, callback);
  },
  getFrame: (original, self) => function (this: unknown, details: any, callback?: (frame: unknown) => void) {
    return callbackify(async () => {
      try {
        return await original.call(self(this), details);
      } catch (error) {
        const message = error instanceof Error ? error.message : '';
        if (message.endsWith('Tab not found.')) return details?.frameId === 0 ? discardedMainFrame(details.tabId) : null;
        if (message.endsWith('Frame not found.') || message.endsWith('Main frame not found.')) return null;
        throw error;
      }
    }, callback);
  },
};

// Chrome follows no extension page past its commit; WebKit reports its whole load.
const extensionPage = /^(chrome|webkit)-extension:/;
const skippingExtensionPages = (name: string) => new WrappedEvent<[any]>(() => bridgeChrome().webNavigation[name], (listener) => (details: any) => {
  if (!extensionPage.test(String(details?.url))) listener(details);
});

export const webNavigationStandIns = {
  // WebKit's details lack transitionType and transitionQualifiers. Lilo cannot tell how a navigation
  // started, so a main frame reports `link` and a subframe `auto_subframe`.
  onCommitted: new WrappedEvent<[any]>(() => bridgeChrome().webNavigation.onCommitted, (listener) => (details: any) => listener({
    transitionType: details?.frameId === 0 ? 'link' : 'auto_subframe', transitionQualifiers: [], ...details,
  })),
  onBeforeNavigate: skippingExtensionPages('onBeforeNavigate'),
  onDOMContentLoaded: skippingExtensionPages('onDOMContentLoaded'),
  onCompleted: skippingExtensionPages('onCompleted'),
  onErrorOccurred: skippingExtensionPages('onErrorOccurred'),
};

export const webNavigationAugmentation = {
  onHistoryStateUpdated: tabResolvingEvent('onHistoryStateUpdated', sameDocumentDetails),
  onReferenceFragmentUpdated: tabResolvingEvent('onReferenceFragmentUpdated', sameDocumentDetails),
  onCreatedNavigationTarget: tabResolvingEvent('onCreatedNavigationTarget', createdNavigationTargetDetails),
  onTabReplaced: new ChromeEvent<[{ replacedTabId: number; tabId: number; timeStamp: number }]>(),
};
