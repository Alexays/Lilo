// WebKit ships no offscreen documents: native loads the page in a hidden web view built from the extension's own
// configuration. Installed only while WebKit lacks chrome.offscreen. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';

const REASONS = [
  'TESTING', 'AUDIO_PLAYBACK', 'IFRAME_SCRIPTING', 'DOM_SCRAPING', 'BLOBS', 'DOM_PARSER', 'USER_MEDIA',
  'DISPLAY_MEDIA', 'WEB_RTC', 'CLIPBOARD', 'LOCAL_STORAGE', 'WORKERS', 'BATTERY_STATUS', 'MATCH_MEDIA',
  'GEOLOCATION',
];

interface CreateParameters {
  url: string;
  reasons: string[];
  justification: string;
}

export const offscreenAugmentation = {
  Reason: Object.fromEntries(REASONS.map((r) => [r, r])),

  createDocument(parameters: CreateParameters, callback?: () => void) {
    return callbackify(async () => {
      if (typeof parameters?.url !== 'string' || !Array.isArray(parameters.reasons) || parameters.reasons.length === 0
        || typeof parameters.justification !== 'string') {
        throw new Error('offscreen.createDocument requires url, reasons and justification');
      }
      await gapCall<null>('offscreen', 'createDocument', { url: parameters.url });
    }, callback);
  },

  closeDocument(callback?: () => void) {
    return callbackify(async () => { await gapCall<null>('offscreen', 'closeDocument'); }, callback);
  },

  hasDocument(callback?: (has: boolean) => void) {
    return callbackify(async () => (await gapCall<string | null>('offscreen', 'documentUrl')) != null, callback);
  },
};

interface ExtensionContext {
  contextType: string;
  contextId: string;
  documentUrl?: string;
  documentOrigin?: string;
  documentId?: string;
  tabId: number;
  frameId: number;
  windowId: number;
  incognito: boolean;
}

interface ContextFilter {
  contextTypes?: string[];
  contextIds?: string[];
  documentUrls?: string[];
  documentOrigins?: string[];
  documentIds?: string[];
  tabIds?: number[];
  frameIds?: number[];
  windowIds?: number[];
  incognito?: boolean;
}

function makeContext(contextType: string, documentUrl: string | undefined, tabId = -1, windowId = -1): ExtensionContext {
  return {
    contextType,
    contextId: `${contextType}:${tabId}:${documentUrl ?? ''}`,
    documentUrl,
    documentOrigin: documentUrl ? new URL(documentUrl).origin : undefined,
    tabId,
    frameId: tabId === -1 ? -1 : 0,
    windowId,
    incognito: false,
  };
}

/**
 * runtime.getContexts: the background, the offscreen document, and extension pages in tabs or on screen outside them.
 * `documentIds` filters match nothing: Lilo has no document ids.
 */
export function getContexts(filter: ContextFilter = {}, callback?: (contexts: ExtensionContext[]) => void) {
  return callbackify(async () => {
    const c = bridgeChrome();
    const manifest = c.runtime.getManifest?.() ?? {};
    const contexts: ExtensionContext[] = [];
    const worker = manifest.background?.service_worker;
    if (typeof worker === 'string') contexts.push(makeContext('BACKGROUND', c.runtime.getURL(worker)));
    if (c.offscreen === offscreenAugmentation) {
      const url = await gapCall<string | null>('offscreen', 'documentUrl').catch(() => null);
      if (url) contexts.push(makeContext('OFFSCREEN_DOCUMENT', url));
    }
    const views = await gapCall<{ contextType: string; url: string }[]>('runtime', 'extensionViews').catch(() => []);
    for (const view of views ?? []) contexts.push(makeContext(view.contextType, view.url));
    const base = c.runtime.getURL('');
    const tabs: any[] = await Promise.resolve(c.tabs?.query?.({})).catch(() => []);
    for (const tab of tabs ?? []) {
      if (typeof tab?.url === 'string' && tab.url.startsWith(base)) {
        contexts.push(makeContext('TAB', tab.url, tab.id, tab.windowId));
      }
    }
    return contexts.filter((ctx) =>
      (!filter.contextTypes || filter.contextTypes.includes(ctx.contextType))
      && (!filter.contextIds || filter.contextIds.includes(ctx.contextId))
      && (!filter.documentUrls || (ctx.documentUrl !== undefined && filter.documentUrls.includes(ctx.documentUrl)))
      && (!filter.documentOrigins || (ctx.documentOrigin !== undefined && filter.documentOrigins.includes(ctx.documentOrigin)))
      && !filter.documentIds
      && (!filter.tabIds || filter.tabIds.includes(ctx.tabId))
      && (!filter.frameIds || filter.frameIds.includes(ctx.frameId))
      && (!filter.windowIds || filter.windowIds.includes(ctx.windowId))
      && (filter.incognito === undefined || filter.incognito === ctx.incognito));
  }, callback);
}
