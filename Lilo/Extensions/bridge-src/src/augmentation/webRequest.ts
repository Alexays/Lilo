// webRequest.onAuthRequired for a proxy's challenge, which WebKit never reports: Lilo pushes it and takes the
// listeners' blocking or asyncBlocking answer; WebKit's other events with Chrome's frames. SW-safe: no window/document/webkit.
import { WrappedEvent } from '../shared/chrome-event.ts';
import { addLeniently } from '../shared/chrome-leniency.ts';
import { gapCall } from '../shared/ipc.ts';
import { GapWrappedEvent, reportGapListener, reportGapListenerRemoved } from '../shared/gap-event.ts';
import { tabAt, type TabPosition } from './tabs.ts';

interface AuthAnswer {
  authCredentials?: { username: string; password: string };
  cancel?: boolean;
}

interface RequestFilter {
  urls?: string[];
  types?: string[];
  tabId?: number;
}

const webSchemes = ['http', 'https', 'ws', 'wss'];
/** Reported by a context with a listener that may answer: Lilo waits for the answer of those contexts only. */
const blockingListener = 'webRequest.onAuthRequired.blocking';

/** Whether a listener's extraInfoSpec lets it answer. */
function blocks(spec: unknown): boolean {
  return Array.isArray(spec) && (spec.includes('blocking') || spec.includes('asyncBlocking'));
}

/** Chrome's match pattern for `url`; a path matches the URL's path and query. */
function matchesPattern(pattern: string, url: URL): boolean {
  const scheme = url.protocol.slice(0, -1);
  if (pattern === '<all_urls>') return webSchemes.includes(scheme);
  const parts = /^(\*|[a-z][a-z0-9+.-]*):\/\/([^/]*)(\/.*)$/.exec(pattern);
  if (!parts) return false;
  const [, patternScheme, patternHost, path] = parts;
  if (patternScheme === '*' ? !webSchemes.includes(scheme) : patternScheme !== scheme) return false;
  const host = patternHost.replace(/:(\d+|\*)$/, '');
  if (host !== '*' && host !== url.hostname && !(host.startsWith('*.') && (url.hostname === host.slice(2) || url.hostname.endsWith(host.slice(1))))) return false;
  const escaped = path.split('*').map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&'));
  return new RegExp(`^${escaped.join('.*')}$`).test(url.pathname + url.search);
}

function applies(filter: RequestFilter | undefined, details: any): boolean {
  if (filter?.types && !filter.types.includes(details.type)) return false;
  if (typeof filter?.tabId === 'number' && filter.tabId !== details.tabId) return false;
  if (!filter?.urls) return true;
  let url: URL;
  try { url = new URL(details.url); } catch { return false; }
  return filter.urls.some((pattern) => matchesPattern(pattern, url));
}

/**
 * Runs the listeners on native's details. A context with a blocking listener sends the first answer giving credentials or
 * cancelling, else an empty one once every listener answered; one without any never answers, as Lilo waits only for the others.
 */
async function receiveAuth(listeners: [(...args: any[]) => unknown, unknown[]][], raw: { tab: TabPosition | null } & Record<string, unknown>): Promise<void> {
  if (listeners.length === 0) return;
  const { tab: position, ...rest } = raw;
  const tab = position ? await tabAt(position).catch(() => undefined) : undefined;
  const details: Record<string, unknown> = { ...rest, tabId: typeof tab?.id === 'number' ? tab.id : -1 };
  let answered = !listeners.some(([, [, spec]]) => blocks(spec));
  const answer = (params: Record<string, unknown>) => {
    if (answered) return;
    answered = true;
    gapCall('webRequest', 'answerAuth', { requestId: details.requestId, ...params }).catch(() => {});
  };
  await Promise.all(listeners.filter(([, [filter]]) => applies(filter as RequestFilter, details)).map(([listener, [, spec]]) => {
    const asyncBlocking = Array.isArray(spec) && spec.includes('asyncBlocking');
    const blocking = Array.isArray(spec) && spec.includes('blocking');
    return new Promise<AuthAnswer | undefined>((resolve) => {
      try {
        const result = listener(details, asyncBlocking ? resolve : undefined);
        if (!asyncBlocking) resolve(blocking ? result as AuthAnswer : undefined);
      } catch (err) {
        console.error(`Error in event handler: ${String(err)}`);
        resolve(undefined);
      }
    }).then((response) => {
      if (response?.cancel) answer({ cancel: true });
      else if (response?.authCredentials) answer({ credentials: response.authCredentials });
    }, () => {});
  }));
  answer({});
}

class AuthRequiredEvent extends GapWrappedEvent<[unknown, unknown?]> {
  override addListener(listener: (details: unknown, callback?: unknown) => void, ...rest: unknown[]): void {
    super.addListener(listener, ...rest);
    if (blocks(this.added.get(listener)?.[1])) reportGapListener(blockingListener);
  }

  override removeListener(listener: (details: unknown, callback?: unknown) => void): void {
    super.removeListener(listener);
    if (![...this.added.values()].some(([, spec]) => blocks(spec))) reportGapListenerRemoved(blockingListener);
  }
}

/** WebKit's onAuthRequired, `source`, which also hears the proxy challenges Lilo pushes. */
export const onAuthRequired = (source: () => object) => new AuthRequiredEvent(
  'webRequest.onAuthRequired',
  source,
  // WebKit's own events only observe: an asyncBlocking listener gets a callback that does nothing.
  (listener) => (details: any) => listener(details, () => {}),
  (listeners, raw) => { void receiveAuth(listeners, raw); },
);

/** The subframes each tab's requests came from since its main frame last loaded. */
const subframes = new Map<number, Set<number>>();

/**
 * Chrome's frames in WebKit's details: WebKit reports a subframe's document as a main_frame request, and its main frame,
 * 0 elsewhere, by its own id as a parent (WEBKIT-GAPS 95). A parent none of the tab's subframes is its main frame.
 */
function chromeFrames(details: any): any {
  const { tabId, frameId, parentFrameId, type } = details ?? {};
  if (typeof tabId !== 'number' || tabId < 0 || typeof frameId !== 'number') return details;
  if (frameId === 0) {
    if (type === 'main_frame') subframes.delete(tabId);
    return details;
  }
  let known = subframes.get(tabId);
  if (!known) subframes.set(tabId, known = new Set());
  known.add(frameId);
  const parent = typeof parentFrameId === 'number' && parentFrameId > 0 && !known.has(parentFrameId) ? 0 : parentFrameId;
  return parent === parentFrameId && type !== 'main_frame' ? details : { ...details, parentFrameId: parent, type: type === 'main_frame' ? 'sub_frame' : type };
}

const FRAME_TYPES = ['main_frame', 'sub_frame'];

/** WebKit's webRequest event `name` with Chrome's frames, its filter's frame types matched on them. */
class ChromeFramesEvent extends WrappedEvent<[any, ...unknown[]]> {
  private readonly filtered = new Map<(...args: any[]) => unknown, (...args: any[]) => unknown>();

  override addListener(listener: (...args: any[]) => unknown, filter?: any, ...rest: unknown[]): void {
    if (this.filtered.has(listener)) return;
    const types: unknown = filter?.types;
    const framed = Array.isArray(types) && types.some((type) => FRAME_TYPES.includes(type)) ? types : undefined;
    const own = framed ? (details: any, ...args: unknown[]) => (framed.includes(details?.type) ? listener(details, ...args) : undefined) : listener;
    addLeniently(framed ? { ...filter, types: [...new Set([...framed, ...FRAME_TYPES])] } : filter, (asked) => {
      super.addListener(own, asked, ...rest);
      this.filtered.set(listener, own);
    });
  }

  override removeListener(listener: (...args: any[]) => unknown): void {
    const own = this.filtered.get(listener);
    if (!own) return;
    this.filtered.delete(listener);
    super.removeListener(own);
  }

  override hasListener(listener: (...args: any[]) => unknown): boolean {
    return this.filtered.has(listener);
  }
}

export const webRequestFrames = (source: (name: string) => object) => Object.fromEntries([
  'onBeforeRequest', 'onBeforeSendHeaders', 'onSendHeaders', 'onHeadersReceived', 'onBeforeRedirect', 'onResponseStarted', 'onCompleted', 'onErrorOccurred',
].map((name) => [name, new ChromeFramesEvent(() => source(name), (listener) => (details: any, ...rest: unknown[]) => listener(chromeFrames(details), ...rest))]));
