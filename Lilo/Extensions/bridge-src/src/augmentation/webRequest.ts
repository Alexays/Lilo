// webRequest.onAuthRequired for a proxy's challenge, which WebKit never reports: Lilo pushes it and takes the
// listeners' blocking or asyncBlocking answer. SW-safe: no window/document/webkit.
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
