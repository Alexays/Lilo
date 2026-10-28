// WebKit refuses runtime messaging to the content scripts of a frame in an extension view no tab shows, such as an
// offscreen document's iframe ("Tab not found", WEBKIT-GAPS 91): the extension page at the top sends their messages
// and opens their ports as its own. Each request carries the extension's key, which its content scripts read from
// their compat and its pages from `_lilo/frame-key` (ExtensionBackgroundPreparer); the frame's page never sees it.
import { bridgeChrome } from './callbackify.ts';
import { ChromeEvent } from './chrome-event.ts';
import { frameMark, listensProbe, otherExtension } from './message-answers.ts';
import { home } from './static-compat.ts';

const keyPattern = /^[0-9a-f]{64}$/;

interface End {
  onMessage: { addListener(listener: (message: unknown) => void): void };
  onDisconnect: { addListener(listener: () => void): void };
  postMessage(message: unknown): void;
  disconnect(): void;
}

/** A port whose end, WebKit's or the relay's, `opened` gives: what is posted meanwhile follows it. */
function deferredPort(name: string, opened: Promise<End>): object {
  let end: End | undefined;
  let early: unknown[] | undefined = [];
  let closed = false;
  const port = {
    name,
    sender: undefined,
    onMessage: new ChromeEvent<[unknown, unknown]>(),
    onDisconnect: new ChromeEvent<[unknown]>(),
    postMessage(message: unknown) {
      if (closed) throw new Error('Attempting to use a disconnected port object');
      if (early) early.push(message);
      else end!.postMessage(message);
    },
    disconnect() {
      if (closed) return;
      closed = true;
      end?.disconnect();
    },
  };
  const lost = () => {
    if (closed) return;
    closed = true;
    port.onDisconnect.dispatch(port);
  };
  opened.then((opener) => {
    end = opener;
    const posted = early!;
    early = undefined;
    if (closed) return opener.disconnect();
    opener.onMessage.addListener((message) => port.onMessage.dispatch(message, port));
    // Synchronous: WebKit's runtime.lastError holds while it runs.
    opener.onDisconnect.addListener(lost);
    for (const message of posted) opener.postMessage(message);
    return undefined;
  }, lost);
  return port;
}

/**
 * Sends `runtime`'s messages and ports through the extension page at the top of this frame once WebKit refuses
 * them for want of a tab; `key` is the one ExtensionBackgroundPreparer writes into the compat.
 */
export function relayFrameMessaging(g: any, runtime: any, key: string): void {
  if (g.top === g || !keyPattern.test(key)) return;
  const ancestors = g.location?.ancestorOrigins;
  const top = ancestors?.[ancestors.length - 1];
  if (typeof top !== 'string' || `${top}/` !== runtime.getURL?.('')) return;
  const target = home(runtime);
  const { sendMessage, connect } = target;
  if (typeof sendMessage !== 'function' || typeof connect !== 'function') return;

  let relays: Promise<boolean> | undefined;
  // Every listener ignores the probe, which reaches them where a tab shows the extension page.
  const relaying = () => (relays ??= Promise.resolve(sendMessage.call(runtime, listensProbe))
    .then(() => false, (error) => /tab not found/i.test(String(error?.message ?? error))));
  /** The port the page at the top answers on. Sent to its origin alone: the key must reach no other page. */
  const request = (data: object) => {
    const channel = new g.MessageChannel();
    g.top.postMessage({ ...data, url: g.location.href, liloFrameKey: key }, top, [channel.port2]);
    return channel.port1;
  };
  const send = (message: unknown) => new Promise((resolve, reject) => {
    const port = request({ send: message });
    port.onmessage = ({ data }: { data: any }) => {
      port.close();
      if ('error' in data) reject(new Error(data.error));
      else resolve(data.response);
    };
  });
  let open: Set<End> | undefined;
  const relayEnd = (port: any): End => {
    // The page at the top learns of no frame that goes: its ports would stay open.
    if (!open) {
      const ends = open = new Set<End>();
      g.addEventListener('pagehide', () => { for (const end of [...ends]) end.disconnect(); });
    }
    const onMessage = new ChromeEvent<[unknown]>();
    const onDisconnect = new ChromeEvent<[]>();
    const end = {
      onMessage, onDisconnect,
      postMessage: (message: unknown) => port.postMessage({ message }),
      disconnect() {
        open!.delete(end);
        port.postMessage({ disconnect: true });
        port.close();
      },
    };
    open.add(end);
    port.onmessage = ({ data }: { data: any }) => {
      if ('message' in data) return onMessage.dispatch(data.message);
      open!.delete(end);
      port.close();
      return onDisconnect.dispatch();
    };
    return end;
  };

  // A content script's runtime.lastError stays WebKit's: a callback learns of no failure. Both are called on runtime, as
  // an extension may call them detached.
  Object.defineProperty(target, 'sendMessage', {
    value(...args: any[]) {
      if (args.length >= 2 && typeof args[1] !== 'function' && otherExtension(args[0], runtime)) return sendMessage.apply(runtime, args);
      const callback = typeof args.at(-1) === 'function' ? args.at(-1) : undefined;
      const sent = callback ? args.slice(0, -1) : args;
      const message = sent.length >= 2 && (sent[0] == null || sent[0] === runtime.id) ? sent[1] : sent[0];
      if (!callback) return relaying().then((relay) => (relay ? send(message) : sendMessage.apply(runtime, args)));
      relaying().then((relay) => {
        if (!relay) return sendMessage.apply(runtime, args);
        return send(message).then((response) => callback(response), () => callback());
      });
      return undefined;
    },
    configurable: true, writable: true,
  });
  Object.defineProperty(target, 'connect', {
    value(...args: any[]) {
      if (otherExtension(args[0], runtime)) return connect.apply(runtime, args);
      const info = typeof args[0] === 'string' || args[0] == null ? args[1] : args[0];
      const name = typeof info?.name === 'string' ? info.name : '';
      return deferredPort(name, relaying().then((relay) => (relay ? relayEnd(request({ connect: name })) : connect.apply(runtime, args))));
    },
    configurable: true, writable: true,
  });
}

/**
 * The extension page at the top of a frame sends the messages and opens the ports of the frame's content scripts
 * (relayFrameMessaging). Its listener runs first, as the page's scripts load later, and keeps each request, and the
 * key in it, from the page's own listeners.
 */
export function acceptFrameMessaging(g: any): void {
  if (g.top !== g || typeof g.fetch !== 'function') return;
  // The page's own: the extension may wrap it later.
  const fetch = g.fetch;
  let known: Promise<string> | undefined;
  g.addEventListener('message', (event: any) => {
    const data = event.data;
    if (typeof data?.liloFrameKey !== 'string') return;
    event.stopImmediatePropagation();
    const port = event.ports?.[0];
    if (!port || typeof data.url !== 'string') return;
    known ??= Promise.resolve(fetch.call(g, bridgeChrome().runtime.getURL('_lilo/frame-key')))
      .then((response: any) => (response.ok ? response.text() : ''))
      .catch(() => '');
    known.then((key) => {
      if (!keyPattern.test(key) || data.liloFrameKey !== key) return port.close();
      const runtime = bridgeChrome().runtime;
      if ('send' in data) {
        return Promise.resolve(runtime.sendMessage({ liloFrame: data.url, message: data.send })).then(
          (response: unknown) => port.postMessage({ response }),
          (error: any) => port.postMessage({ error: String(error?.message ?? error) }),
        );
      }
      const remote = runtime.connect({ name: `${String(data.connect)}${frameMark}${encodeURIComponent(data.url)}` });
      remote.onMessage.addListener((message: unknown) => port.postMessage({ message }));
      remote.onDisconnect.addListener(() => port.postMessage({ disconnect: true }));
      port.onmessage = ({ data: relayed }: { data: any }) => {
        if ('message' in relayed) {
          try { remote.postMessage(relayed.message); } catch { /* the other end went */ }
          return;
        }
        port.close();
        remote.disconnect();
      };
      return undefined;
    });
  }, true);
}
