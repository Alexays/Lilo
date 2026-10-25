// Chrome on a Mac never fires onSuspend/onSuspendCanceled on a worker, onRestartRequired/restart outside ChromeOS
// kiosks, nor onConnectNative without a native host, which Lilo never starts. SW-safe: no window/document/webkit.
import { bridgeEvents, gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify, withLastError } from '../shared/callbackify.ts';
import { ChromeEvent, WrappedEvent } from '../shared/chrome-event.ts';
import { GapChromeEvent, GapWrappedEvent } from '../shared/gap-event.ts';
import { messagesOnce, once } from '../shared/message-answers.ts';
import type { Patch } from '../shared/chrome-compat.ts';

interface UpdateCheckResult {
  status: 'throttled' | 'no_update' | 'update_available';
  version: string;
}

const kioskOnly = 'API available only for ChromeOS kiosk mode.';

export const runtimeAdditions = {
  onSuspend: new ChromeEvent<[]>(),
  onSuspendCanceled: new ChromeEvent<[]>(),
  onRestartRequired: new ChromeEvent<[string]>(),
  onEnabled: new GapChromeEvent<[]>('runtime', 'onEnabled'),
  onExtensionLoaded: new GapChromeEvent<[{ reason: string; previousVersion?: string }]>('runtime', 'onExtensionLoaded'),
  onUpdateAvailable: new GapChromeEvent<[Record<string, unknown>]>('runtime', 'onUpdateAvailable'),
  /** The promise gets `{ status, version }`; a callback gets `(status, { version })`, as in Chrome. */
  requestUpdateCheck(callback?: (status?: string, details?: { version: string }) => void) {
    // The check waits on Google's update service.
    return callbackify(
      () => gapCall<UpdateCheckResult>('runtime', 'requestUpdateCheck', {}, 0),
      callback && ((result?: UpdateCheckResult) => (result ? callback(result.status, { version: result.version }) : callback())),
    );
  },
  restart() {
    // Chrome reports this through runtime.lastError, which nothing can check here.
    console.error('Unchecked runtime.lastError: Function available only for ChromeOS kiosk mode.');
  },
  restartAfterDelay(_seconds: number, callback?: () => void) {
    return callbackify(() => Promise.reject(new Error(kioskOnly)), callback);
  },
};

export const onConnectNative = new ChromeEvent<[unknown]>();

/**
 * Take the listeners of WebKit's, which picks onStartup and an install by how soon after its controller
 * a context loads and sometimes drops an update: Lilo pushes them for the loads Chrome fires them on.
 */
export const runtimeLifecycle = {
  onInstalled: new GapChromeEvent<[{ reason: string; previousVersion?: string }]>('runtime', 'onInstalled'),
  onStartup: new GapChromeEvent<[]>('runtime', 'onStartup'),
};

const noReceiver = 'Could not establish connection. Receiving end does not exist.';

const isWorker = typeof (globalThis as any).ServiceWorkerGlobalScope === 'function';

/** Ends, before `once`, the name of the port tabs.connect opens to the extension's own page a tab shows, with its url. */
const tabMark = '?liloTab=';

/**
 * WebKit's runtime.onConnect, `source`, handing out the port chrome.runtime.connect opened as messagesOnce's. A port
 * tabs.connect opened to the pages a tab shows reaches only those.
 */
export const onConnect = (source: () => object) => new WrappedEvent<[any]>(source, (listener) => (port: any) => {
  const name = port?.name;
  if (typeof name !== 'string' || !name.endsWith(once)) return listener(port);
  const plain = name.slice(0, -once.length);
  const tab = plain.lastIndexOf(tabMark);
  // The page the tab shows takes it, synchronously: a message the port delivers before its listener runs is lost. The
  // other contexts hold it all the same: one letting go before every process took the port disconnects it, and its
  // first messages, queued, with it (WEBKIT-GAPS 60).
  if (tab >= 0) {
    const shown = (globalThis as any).top === globalThis && (globalThis as any).location?.href === plain.slice(tab + tabMark.length);
    return shown ? listener(messagesOnce(port, plain.slice(0, tab))) : undefined;
  }
  return listener(messagesOnce(port, plain));
});

/**
 * tabs.connect, which Chrome also connects to the extension's own pages a tab shows, where WebKit reaches content
 * scripts only: once `tabs.get` finds such a page in the tab, the port goes to the extension's pages at its url
 * instead, with what was posted meanwhile. A port to a frame by id stays WebKit's.
 */
export const tabsConnect: Patch = (original, self) => function (this: unknown, tabId: number, info?: { name?: string; frameId?: number; documentId?: string }) {
  const tabs: any = self(this);
  const webKit = original.apply(tabs, info === undefined ? [tabId] : [tabId, info]);
  if (info?.documentId !== undefined || (info?.frameId ?? 0) !== 0) return webKit;
  const runtime = bridgeChrome().runtime;
  const name = typeof info?.name === 'string' ? info.name : '';
  let end = webKit;
  let early: unknown[] | undefined = [];
  // WebKit's port went before tabs.get answered: its runtime.lastError, null without one.
  let lost: string | null | undefined;
  let closed = false;
  const port = {
    name,
    sender: undefined,
    onMessage: new ChromeEvent<[unknown, unknown]>(),
    onDisconnect: new ChromeEvent<[unknown]>(),
    postMessage(message: unknown) {
      if (closed) throw new Error('Attempting to use a disconnected port object');
      early?.push(message);
      end.postMessage(message);
    },
    disconnect() {
      if (closed) return;
      closed = true;
      end.disconnect();
    },
  };
  const follow = (source: any) => {
    source.onMessage.addListener((message: unknown) => { if (end === source) port.onMessage.dispatch(message, port); });
    source.onDisconnect.addListener(() => {
      if (end !== source || closed) return;
      if (early) {
        lost = runtime.lastError?.message ?? null;
        return;
      }
      closed = true;
      port.onDisconnect.dispatch(port);
    });
  };
  follow(webKit);
  const get = tabs.get.__liloUnwrapped ?? tabs.get;
  Promise.resolve(get.call(tabs, tabId)).catch(() => undefined).then((tab: any) => {
    const posted = early!;
    early = undefined;
    if (closed) return;
    if (typeof tab?.url === 'string' && tab.url.startsWith(runtime.getURL(''))) {
      // chrome.runtime.connect marks it as a port both of whose ends are Lilo's.
      end = runtime.connect({ name: `${name}${tabMark}${tab.url}` });
      follow(end);
      webKit.disconnect();
      for (const message of posted) end.postMessage(message);
    } else if (lost !== undefined) {
      closed = true;
      if (lost === null) port.onDisconnect.dispatch(port);
      else withLastError(lost, () => port.onDisconnect.dispatch(port));
    }
  });
  return port;
};

// Chrome's ids, and Lilo's for an unpacked extension without a manifest key.
const otherExtension = (id: unknown, runtime: any) => typeof id === 'string' && /^([a-p]{32}|extension-[0-9a-f]{16})$/.test(id) && id !== runtime.id;
const portClosed = 'The message port closed before a response was received.';
/** What the other extension learns of this context as its sender: native checks the url and adds the id and origin. */
async function senderInfo(): Promise<Record<string, unknown>> {
  const info: Record<string, unknown> = {};
  const url = (globalThis as any).location?.href;
  if (url) info.url = url;
  if (!isWorker) {
    const tab = await Promise.resolve(bridgeChrome()?.tabs?.getCurrent?.()).catch(() => undefined);
    if (tab) info.tab = tab;
  }
  return info;
}

/** This context's ends of the ports native relays between extensions, by port id: each takes a message, or undefined for a disconnect. */
const externalPorts = new Map<string, (message?: { data: unknown }) => void>();
bridgeEvents.set('runtime.portMessage', (portId: string, data: unknown) => externalPorts.get(portId)?.({ data }));
bridgeEvents.set('runtime.portDisconnect', (portId: string) => externalPorts.get(portId)?.());

/**
 * A port native relays to another extension, by the id `opened` gives (a connecting extension's port, at once); a
 * rejection disconnects it with that error.
 */
function externalPort(name: string, sender: unknown, opened: Promise<string> | string): object {
  let portId: string | undefined;
  let closed = false;
  let sending: Promise<unknown>;
  const receive = (message?: { data: unknown }) => {
    if (message) return port.onMessage.dispatch(message.data, port);
    closed = true;
    externalPorts.delete(portId!);
    port.onDisconnect.dispatch(port);
  };
  const port = {
    name,
    sender,
    onMessage: new ChromeEvent<[unknown, unknown]>(),
    onDisconnect: new ChromeEvent<[unknown]>(),
    postMessage(message: unknown) {
      if (closed) throw new Error('Attempting to use a disconnected port object');
      sending = sending.then(() => portId && gapCall('runtime', 'portPost', { portId, message })).catch(() => {});
    },
    disconnect() {
      if (closed) return;
      closed = true;
      sending = sending.then(() => {
        if (!portId) return undefined;
        externalPorts.delete(portId);
        return gapCall('runtime', 'portDisconnect', { portId });
      }).catch(() => {});
    },
  };
  if (typeof opened === 'string') {
    // Its messages may follow in the same batch of events.
    portId = opened;
    externalPorts.set(opened, receive);
    sending = Promise.resolve();
    return port;
  }
  sending = opened.then((id) => {
    portId = id;
    if (!closed) externalPorts.set(id, receive);
  }, (error) => {
    closed = true;
    withLastError(error?.message ?? noReceiver, () => port.onDisconnect.dispatch(port));
  });
  return port;
}

/**
 * chrome.runtime's connect and sendMessage, which Lilo relays to another extension's onConnectExternal and
 * onMessageExternal (WebKit has no cross-extension messaging); `sendLocal` sends the extension's own messages.
 */
export function crossExtensionMessaging(runtime: any, sendLocal: (...args: any[]) => any = (...args) => runtime.sendMessage(...args)) {
  return {
    connect(...args: any[]) {
      if (!otherExtension(args[0], runtime)) {
        const [id, info] = typeof args[0] === 'string' ? args : [undefined, args[0]];
        const name = typeof info?.name === 'string' ? info.name : '';
        const marked = { ...info, name: name + once };
        return messagesOnce(id === undefined ? runtime.connect(marked) : runtime.connect(id, marked), name);
      }
      const name = typeof args[1]?.name === 'string' ? args[1].name : '';
      const opened = senderInfo().then((sender) => gapCall<string>('runtime', 'connectExternal', { id: args[0], name, ...sender }));
      return externalPort(name, undefined, opened);
    },
    sendMessage(...args: any[]) {
      if (args.length < 2 || typeof args[1] === 'function' || !otherExtension(args[0], runtime)) return sendLocal(...args);
      const callback = typeof args.at(-1) === 'function' ? args.at(-1) : undefined;
      // No timeout: the other extension may keep the channel open, as in Chrome.
      const sent = senderInfo().then((sender) => gapCall<{ response?: unknown }>('runtime', 'sendExternal', { id: args[0], message: args[1], ...sender }, 0));
      if (!callback) return sent.then((answer) => answer?.response);
      sent.then(
        (answer) => (answer && 'response' in answer ? callback(answer.response) : withLastError(portClosed, () => callback())),
        (error) => withLastError(error?.message ?? noReceiver, () => callback()),
      );
      return undefined;
    },
  };
}

/** Runs onMessageExternal's listeners on a message native relays from another extension, and sends their answer. */
function receiveExternalMessage(listeners: [(...args: any[]) => unknown, unknown[]][], message: unknown, sender: unknown, messageId: string): void {
  // The worker answers for the extension, a page only when it listens.
  if (listeners.length === 0 && !isWorker) return;
  let answered = false;
  let open = false;
  const respond = (response?: unknown) => {
    if (answered) return;
    answered = true;
    gapCall('runtime', 'answerExternal', { messageId, response: response === undefined ? null : response }).catch(() => {});
  };
  for (const [listener] of listeners) {
    try {
      const result = listener(message, sender, respond);
      if (result === true) {
        open = true;
      } else if (typeof (result as PromiseLike<unknown>)?.then === 'function') {
        open = true;
        Promise.resolve(result).then(respond, () => respond());
      }
    } catch (err) {
      console.error(`Error in event handler: ${String(err)}`);
    }
  }
  if (!answered && !open) gapCall('runtime', 'answerExternal', { messageId, worker: isWorker }).catch(() => {});
}

/** WebKit's onMessageExternal and onConnectExternal, which web pages reach, also hearing the extensions Lilo relays. */
export const externalEvents = (runtime: () => any) => ({
  onMessageExternal: new GapWrappedEvent<[unknown, unknown, unknown]>(
    'runtime.onMessageExternal', () => runtime().onMessageExternal, (listener) => listener,
    (listeners, message, sender, messageId) => receiveExternalMessage(listeners, message, sender, messageId),
  ),
  onConnectExternal: new GapWrappedEvent<[unknown]>(
    'runtime.onConnectExternal', () => runtime().onConnectExternal, (listener) => listener,
    (listeners, info: { portId: string; name: string; sender: unknown }) => {
      if (listeners.length === 0) return;
      const port = externalPort(info.name, info.sender, info.portId);
      for (const [listener] of listeners) {
        try { listener(port); } catch (err) { console.error(`Error in event handler: ${String(err)}`); }
      }
    },
  ),
});

