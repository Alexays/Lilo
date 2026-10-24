// WebKit delivers no postMessage between an extension page and its worker, Chrome does (MultiPassword relies on it).
// SW-safe: only globalThis-style lookups on the given scope.

const CHANNEL = 'lilo-worker-messages';

type Envelope = { page: string; toWorker: boolean; data: unknown; url?: string };

export function installPageWorkerMessages(scope: any): void {
  const { ServiceWorker, BroadcastChannel, location } = scope;
  const container = scope.navigator?.serviceWorker;
  if (!ServiceWorker || !BroadcastChannel || !container || !location) return;
  // Built from protocol and host because a custom-scheme origin may serialize as "null".
  const base = `${location.protocol}//${location.host}/`;
  const page = scope.crypto.randomUUID();
  const channel = new BroadcastChannel(CHANNEL);
  const post = ServiceWorker.prototype.postMessage;
  ServiceWorker.prototype.postMessage = function (this: { scriptURL: string }, data: unknown, ...rest: unknown[]) {
    if (!this.scriptURL.startsWith(base)) return post.call(this, data, ...rest);
    channel.postMessage({ page, toWorker: true, data, url: location.href } satisfies Envelope);
  };
  channel.onmessage = ({ data }: { data: Envelope }) => {
    if (data?.toWorker !== false || data.page !== page) return;
    container.dispatchEvent(new scope.MessageEvent('message', { data: data.data }));
  };
  // WebKit scopes the worker to its script's directory, Chrome to the extension's root: a page outside
  // that directory (MultiPassword's, whose worker is in background/) would wait for it forever.
  const nativeReady = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(container), 'ready')?.get;
  let ready: Promise<unknown> | undefined;
  Object.defineProperty(container, 'ready', {
    configurable: true,
    get: () => ready ??= new Promise((resolve) => {
      nativeReady?.call(container).then(resolve);
      const find = () => container.getRegistrations().then((registrations: { active?: { scriptURL: string } }[]) => {
        const own = registrations.find((registration) => registration.active?.scriptURL.startsWith(base));
        if (own) resolve(own);
        else scope.setTimeout(find, 100);
      });
      find();
    }),
  });
}

export function installWorkerClientMessages(scope: any): void {
  const { BroadcastChannel, WindowClient } = scope;
  if (!BroadcastChannel || !WindowClient) return;
  const channel = new BroadcastChannel(CHANNEL);
  const Event = scope.ExtendableMessageEvent ?? scope.MessageEvent;
  channel.onmessage = ({ data }: { data: Envelope }) => {
    if (data?.toWorker !== true || typeof data.url !== 'string') return;
    // A WindowClient, as Chrome's source is: extensions check it comes from one of their own pages.
    const source = Object.create(WindowClient.prototype, {
      id: { value: data.page },
      url: { value: data.url },
      type: { value: 'window' },
      frameType: { value: 'top-level' },
      postMessage: { value: (answer: unknown) => channel.postMessage({ page: data.page, toWorker: false, data: answer } satisfies Envelope) },
    });
    const event = new Event('message', { data: data.data, origin: new URL(data.url).origin });
    Object.defineProperty(event, 'source', { value: source });
    scope.dispatchEvent(event);
  };
}
