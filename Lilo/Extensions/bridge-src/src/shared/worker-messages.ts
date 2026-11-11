// WebKit delivers no postMessage between an extension page and its worker, Chrome does (MultiPassword relies on it).
// SW-safe: only globalThis-style lookups on the given scope.

import { gapCall } from './ipc.ts';

const CHANNEL = 'lilo-worker-messages';

/** Without a `page`, a worker's message goes to every page showing `url`. */
type Envelope = { page?: string; toWorker: boolean; data: unknown; url?: string; ports?: string[] };
/** A message on a transferred port, which BroadcastChannel cannot carry: each end relays its own real port. */
type PortEnvelope = { port: string; toWorker: boolean; data: unknown };

/** The real ends this context relays over each channel, by port id: one listener serves them all. */
const relayed = new WeakMap<object, Map<string, { port: any; toWorker: boolean }>>();

/** Relays `port` over `channel` as the page's end of `id` when `toWorker`, else as the worker's. */
function relayPort(channel: any, port: any, id: string, toWorker: boolean): void {
  let ends = relayed.get(channel);
  if (!ends) {
    const all = new Map<string, { port: any; toWorker: boolean }>();
    relayed.set(channel, ends = all);
    channel.addEventListener('message', ({ data }: { data: PortEnvelope }) => {
      const end = typeof data?.port === 'string' ? all.get(data.port) : undefined;
      if (end && data.toWorker !== end.toWorker) end.port.postMessage(data.data);
    });
  }
  ends.set(id, { port, toWorker });
  port.onmessage = ({ data }: { data: unknown }) => channel.postMessage({ port: id, toWorker, data } satisfies PortEnvelope);
}

export function installPageWorkerMessages(scope: any): void {
  const { ServiceWorker, BroadcastChannel, location } = scope;
  const container = scope.navigator?.serviceWorker;
  if (!ServiceWorker || !BroadcastChannel || !container || !location) return;
  // Built from protocol and host because a custom-scheme origin may serialize as "null".
  const base = `${location.protocol}//${location.host}/`;
  const page = scope.crypto.randomUUID();
  const channel = new BroadcastChannel(CHANNEL);
  const post = ServiceWorker.prototype.postMessage;
  ServiceWorker.prototype.postMessage = function (this: { scriptURL: string }, data: unknown, ...rest: any[]) {
    if (!this.scriptURL.startsWith(base)) return post.call(this, data, ...rest);
    const transfer: unknown[] = Array.isArray(rest[0]) ? rest[0] : rest[0]?.transfer ?? [];
    const ports = transfer.filter((item) => item instanceof scope.MessagePort).map((port) => {
      const id = scope.crypto.randomUUID();
      relayPort(channel, port, id, true);
      return id;
    });
    channel.postMessage({ page, toWorker: true, data, url: location.href, ports } satisfies Envelope);
  };
  channel.addEventListener('message', ({ data }: { data: Envelope }) => {
    if (data?.toWorker !== false || (data.page ? data.page !== page : data.url !== location.href)) return;
    container.dispatchEvent(new scope.MessageEvent('message', { data: data.data }));
  });
  // WebKit scopes the worker to its script's directory, Chrome to the extension's root: a page outside
  // that directory (MultiPassword's, whose worker is in background/) would wait for it forever.
  const nativeReady = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(container), 'ready')?.get;
  let ready: Promise<unknown> | undefined;
  Object.defineProperty(container, 'ready', {
    configurable: true,
    // As Chrome's, it never resolves without a worker.
    get: () => ready ??= scope.chrome?.runtime?.getManifest?.()?.background?.service_worker ? new Promise((resolve) => {
      let settled = false;
      const settle = (registration: unknown) => { settled = true; resolve(registration); };
      nativeReady?.call(container).then(settle);
      const own = (): Promise<unknown> => container.getRegistrations().then((registrations: { active?: { scriptURL: string } }[]) =>
        registrations.find((registration) => registration.active?.scriptURL.startsWith(base)));
      // WebKit can find no registration from a process that loaded the worker, as MultiPassword's offscreen document
      // (WEBKIT-GAPS 92): once the worker answers or starts, a stand-in takes the messages, which go over the channel anyway.
      channel.addEventListener('message', ({ data }: { data: { pong?: string; started?: boolean } }) => {
        if ((data?.pong === page || data?.started) && !settled) own().then((found) => settle(found ?? workerStandIn(scope, base)));
      });
      // The looks space out and stop after 3 s: a worker that starts later announces itself.
      let delay = 100;
      const find = () => own().then((found) => {
        if (settled) return;
        if (found) return settle(found);
        channel.postMessage({ ping: page });
        if (delay > 3000) return;
        scope.setTimeout(find, delay);
        delay *= 2;
      });
      find();
    }) : nativeReady?.call(container) ?? new Promise(() => {}),
  });
}

/** A registration of the extension's worker, named by its manifest as Chrome names it, that only carries messages. */
function workerStandIn(scope: any, base: string): object {
  const scriptURL = new URL(scope.chrome?.runtime?.getManifest?.()?.background?.service_worker ?? '', base).href;
  const active = Object.create(scope.ServiceWorker.prototype, { scriptURL: { value: scriptURL }, state: { value: 'activated' } });
  return Object.create(scope.ServiceWorkerRegistration?.prototype ?? Object.prototype, {
    active: { value: active }, installing: { value: null }, waiting: { value: null }, scope: { value: new URL('.', scriptURL).href },
  });
}

export function installWorkerClientMessages(scope: any): void {
  const { BroadcastChannel, WindowClient } = scope;
  if (!BroadcastChannel || !WindowClient) return;
  const channel = new BroadcastChannel(CHANNEL);
  const Event = scope.ExtendableMessageEvent ?? scope.MessageEvent;
  // A WindowClient, as Chrome's is: extensions check a message comes from one of their own pages.
  const client = (id: string, url: string, page?: string) => Object.create(WindowClient.prototype, {
    id: { value: id },
    url: { value: url },
    type: { value: 'window' },
    frameType: { value: 'top-level' },
    postMessage: { value: (data: unknown) => channel.postMessage({ page, toWorker: false, data, url } satisfies Envelope) },
  });
  const { clients } = scope;
  const matchAll = clients?.matchAll;
  if (matchAll) {
    // WebKit counts no extension page as a client: Lilo names the open ones.
    clients.matchAll = async (options?: { type?: string }) => {
      const own: { url: string }[] = await matchAll.call(clients, options);
      if (options?.type === 'worker' || options?.type === 'sharedworker') return own;
      const pages = await gapCall<string[]>('runtime', 'clientPages').catch(() => []);
      return [...own, ...pages.filter((url) => !own.some((found) => found.url === url)).map((url) => client(url, url))];
    };
  }
  channel.addEventListener('message', ({ data }: { data: Envelope & { ping?: string } }) => {
    if (typeof data?.ping === 'string') return channel.postMessage({ pong: data.ping });
    if (data?.toWorker !== true || typeof data.url !== 'string') return;
    // The worker's ends are real ports, so their start, queueing and close behave as Chrome's.
    const ports = (data.ports ?? []).map((id) => {
      const { port1, port2 } = new scope.MessageChannel();
      relayPort(channel, port2, id, false);
      return port1;
    });
    const event = new Event('message', { data: data.data, origin: new URL(data.url).origin, ports });
    // WebKit's waitUntil throws InvalidStateError on a script-built event; its promise has no worker lifetime to extend.
    Object.defineProperties(event, {
      source: { value: client(data.page ?? data.url, data.url, data.page) },
      waitUntil: { value: (promise: unknown) => { Promise.resolve(promise).catch(() => {}); } },
    });
    scope.dispatchEvent(event);
  });
  channel.postMessage({ started: true });
}
