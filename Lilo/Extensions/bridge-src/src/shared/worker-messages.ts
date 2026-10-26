// WebKit delivers no postMessage between an extension page and its worker, Chrome does (MultiPassword relies on it).
// SW-safe: only globalThis-style lookups on the given scope.

const CHANNEL = 'lilo-worker-messages';

type Envelope = { page: string; toWorker: boolean; data: unknown; url?: string; ports?: string[] };
/** A message on a transferred port, which BroadcastChannel cannot carry: each end relays its own real port. */
type PortEnvelope = { port: string; toWorker: boolean; data: unknown };

/** Relays `port` over `channel` as the page's end of `id` when `toWorker`, else as the worker's. */
function relayPort(channel: any, port: any, id: string, toWorker: boolean): void {
  port.onmessage = ({ data }: { data: unknown }) => channel.postMessage({ port: id, toWorker, data } satisfies PortEnvelope);
  channel.addEventListener('message', ({ data }: { data: PortEnvelope }) => {
    if (data?.port === id && data.toWorker !== toWorker) port.postMessage(data.data);
  });
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
    if (data?.toWorker !== false || data.page !== page) return;
    container.dispatchEvent(new scope.MessageEvent('message', { data: data.data }));
  });
  // WebKit scopes the worker to its script's directory, Chrome to the extension's root: a page outside
  // that directory (MultiPassword's, whose worker is in background/) would wait for it forever.
  const nativeReady = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(container), 'ready')?.get;
  let ready: Promise<unknown> | undefined;
  Object.defineProperty(container, 'ready', {
    configurable: true,
    get: () => ready ??= new Promise((resolve) => {
      let settled = false;
      const settle = (registration: unknown) => { settled = true; resolve(registration); };
      nativeReady?.call(container).then(settle);
      const own = (): Promise<unknown> => container.getRegistrations().then((registrations: { active?: { scriptURL: string } }[]) =>
        registrations.find((registration) => registration.active?.scriptURL.startsWith(base)));
      // WebKit can find no registration from a process that loaded the worker, as MultiPassword's offscreen document
      // (WEBKIT-GAPS 92): once the worker answers, a stand-in takes the messages, which go over the channel anyway.
      channel.addEventListener('message', ({ data }: { data: { pong?: string } }) => {
        if (data?.pong === page && !settled) own().then((found) => settle(found ?? workerStandIn(scope, base)));
      });
      const find = () => own().then((found) => {
        if (settled) return;
        if (found) return settle(found);
        channel.postMessage({ ping: page });
        scope.setTimeout(find, 100);
      });
      find();
    }),
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
  channel.addEventListener('message', ({ data }: { data: Envelope & { ping?: string } }) => {
    if (typeof data?.ping === 'string') return channel.postMessage({ pong: data.ping });
    if (data?.toWorker !== true || typeof data.url !== 'string') return;
    // The worker's ends are real ports, so their start, queueing and close behave as Chrome's.
    const ports = (data.ports ?? []).map((id) => {
      const { port1, port2 } = new scope.MessageChannel();
      relayPort(channel, port2, id, false);
      return port1;
    });
    // A WindowClient, as Chrome's source is: extensions check it comes from one of their own pages.
    const source = Object.create(WindowClient.prototype, {
      id: { value: data.page },
      url: { value: data.url },
      type: { value: 'window' },
      frameType: { value: 'top-level' },
      postMessage: { value: (answer: unknown) => channel.postMessage({ page: data.page, toWorker: false, data: answer } satisfies Envelope) },
    });
    const event = new Event('message', { data: data.data, origin: new URL(data.url).origin, ports });
    // WebKit's waitUntil throws InvalidStateError on a script-built event; its promise has no worker lifetime to extend.
    Object.defineProperties(event, {
      source: { value: source },
      waitUntil: { value: (promise: unknown) => { Promise.resolve(promise).catch(() => {}); } },
    });
    scope.dispatchEvent(event);
  });
}
