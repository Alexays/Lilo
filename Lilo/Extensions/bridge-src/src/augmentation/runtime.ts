// Chrome on a Mac never fires onSuspend/onSuspendCanceled on a worker, onRestartRequired/restart outside ChromeOS
// kiosks, nor onConnectNative without a native host, which Lilo never starts. SW-safe: no window/document/webkit.
import { bridgeEvents, gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify, withLastError } from '../shared/callbackify.ts';
import { ChromeEvent, WrappedEvent } from '../shared/chrome-event.ts';
import { GapChromeEvent, GapWrappedEvent, reportGapListener } from '../shared/gap-event.ts';
import { externalMark, messagesOnce, noReceiver, once, otherExtension } from '../shared/message-answers.ts';
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

const isWorker = typeof (globalThis as any).ServiceWorkerGlobalScope === 'function';

/** Ends, before `once`, the name of the port tabs.connect opens to the extension's own page a tab shows, with its url. */
const tabMark = '?liloTab=';

/**
 * The port Lilo relays from another page or the worker of the extension, to `listeners`: one tabs.connect opened to the
 * pages a tab shows reaches only the page it shows. A context that takes it says so, as one with no listener declines it.
 */
function receiveLocalPort(listeners: [(...args: any[]) => unknown, unknown[]][], info: { portId: string; name: string; sender: unknown }): void {
  const tab = info.name.lastIndexOf(tabMark);
  const shown = tab < 0 || ((globalThis as any).top === globalThis && (globalThis as any).location?.href === info.name.slice(tab + tabMark.length));
  if (listeners.length === 0 || !shown) {
    gapCall('runtime', 'portDecline', { portId: info.portId }, 0).catch(() => {});
    return;
  }
  const port = externalPort(tab < 0 ? info.name : info.name.slice(0, tab), info.sender, info.portId);
  gapCall('runtime', 'portAccept', { portId: info.portId }, 0).catch(() => {});
  for (const [listener] of listeners) {
    try { listener(port); } catch (err) { console.error(`Error in event handler: ${String(err)}`); }
  }
}

/**
 * WebKit's runtime.onConnect, `source`, which also hears the ports Lilo relays between the extension's pages and worker.
 * WebKit's port a content script's chrome.runtime.connect opened goes out as messagesOnce's; one a content script opened
 * to another extension goes to the worker, which relays it.
 */
export const onConnect = (source: () => object) => new GapWrappedEvent<[any]>('runtime.onConnect', source, (listener) => (port: any) => {
  const name = port?.name;
  if (typeof name !== 'string' || !name.endsWith(once)) return listener(port);
  const plain = name.slice(0, -once.length);
  const external = plain.lastIndexOf(externalMark);
  if (external >= 0) {
    return isWorker ? relayContentScriptPort(port, plain.slice(0, external), plain.slice(external + externalMark.length)) : undefined;
  }
  return listener(messagesOnce(port, plain));
}, receiveLocalPort);

/**
 * tabs.connect, which Chrome also connects to the extension's own pages a tab shows, where WebKit reaches content
 * scripts only: once `tabs.get` finds such a page in the tab, the port goes to the extension's pages at its url
 * instead, with what was posted meanwhile. A port to a frame by id stays WebKit's.
 */
export const tabsConnect: Patch = (original, self) => function (this: unknown, tabId: number, info?: { name?: string; frameId?: number; documentId?: string }) {
  const tabs: any = self(this);
  const name = typeof info?.name === 'string' ? info.name : '';
  // WebKit throws when no script of the tab listens, where Chrome's port disconnects (WEBKIT-GAPS 93).
  const webKit = connectOrUnanswered(() => original.apply(tabs, info === undefined ? [tabId] : [tabId, info]), name);
  if (info?.documentId !== undefined || (info?.frameId ?? 0) !== 0) return webKit;
  const runtime = bridgeChrome().runtime;
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

const portClosed = 'The message port closed before a response was received.';

/** What the other extension learns of this context as its sender: native checks the url and adds the id and origin. */
async function senderInfo(): Promise<Record<string, unknown>> {
  const info: Record<string, unknown> = {};
  const url = (globalThis as any).location?.href;
  if (url) info.url = url;
  if (!isWorker) {
    // WebKit's getCurrent sometimes never answers in a page a tab shows: the message then goes without its tab.
    const unanswered = new Promise((resolve) => setTimeout(resolve, 500));
    const tab = await Promise.race([Promise.resolve(bridgeChrome()?.tabs?.getCurrent?.()).catch(() => undefined), unanswered]);
    if (tab) info.tab = tab;
  }
  return info;
}

/**
 * This context's ends of the ports native relays between extensions, by port id: each takes a message, or undefined for a
 * disconnect, with its lastError if any.
 */
const externalPorts = new Map<string, (message?: { data: unknown }, error?: string) => void>();
// Messages come as their JSON, which native relays without reading: Chrome serializes a port's messages as JSON too.
// Chrome runs each port message as a task of its own, so what a listener schedules runs before the next message: Lilo,
// which receives them batched, does too. A disconnect follows the messages before it.
const portTasks: Array<() => void> = [];
let taskChannel: MessageChannel | undefined;
function asTask(task: () => void): void {
  if (typeof MessageChannel !== 'function') return task();
  if (!taskChannel) {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      portTasks.shift()?.();
      // An open channel would keep a process that has nothing else to do running.
      if (portTasks.length === 0 && taskChannel === channel) {
        taskChannel = undefined;
        channel.port1.close();
      }
    };
    taskChannel = channel;
  }
  portTasks.push(task);
  taskChannel.port2.postMessage(null);
}
// Not even the first runs in the event's task: the port's onConnect, which Lilo may send in the same message, has one of its own.
bridgeEvents.set('runtime.portMessages', (portId: string, json: string) => {
  if (typeof json !== 'string') return;
  for (const data of JSON.parse(json)) asTask(() => externalPorts.get(portId)?.({ data }));
});
bridgeEvents.set('runtime.portDisconnect', (portId: string, error?: string) => asTask(() => externalPorts.get(portId)?.(undefined, error)));

/**
 * A port native relays to another extension, by the id `opened` gives (a connecting extension's port, at once); a
 * rejection disconnects it with that error.
 */
function externalPort(name: string, sender: unknown, opened: Promise<string> | string): object {
  // Native sends a context only the events it listens to: a page, or a worker whose report would leave them out.
  reportGapListener('runtime.portMessages');
  reportGapListener('runtime.portDisconnect');
  let portId: string | undefined;
  let closed = false;
  let sending: Promise<unknown>;
  // What is posted until the next task goes as JSON in as few calls as fit BATCH_LENGTH each: the answers to a burst of
  // messages, each its own task, go together.
  let queued: string[][] = [];
  let queuedLength = 0;
  const flush = () => {
    if (queued.length === 0) return;
    const batches = queued;
    queued = [];
    sending = sending.then(() => {
      if (!portId) return;
      for (const batch of batches) gapCall('runtime', 'portPost', { portId, json: `[${batch.join(',')}]` }, 0).catch(() => {});
    });
  };
  const receive = (message?: { data: unknown }, error?: string) => {
    if (message) return closed ? undefined : port.onMessage.dispatch(message.data, port);
    closed = true;
    externalPorts.delete(portId!);
    if (error) withLastError(error, () => port.onDisconnect.dispatch(port));
    else port.onDisconnect.dispatch(port);
  };
  const port = {
    name,
    sender,
    onMessage: new ChromeEvent<[unknown, unknown]>(),
    onDisconnect: new ChromeEvent<[unknown]>(),
    // Each call goes once the port has its id, in order over the channel: none waits for the answer to the one before.
    postMessage(message: unknown) {
      if (closed) throw new Error('Attempting to use a disconnected port object');
      // Serialized now, so a message JSON cannot hold throws here, as in Chrome.
      const json = JSON.stringify(message === undefined ? null : message);
      const first = queued.length === 0;
      if (first || queuedLength + json.length > BATCH_LENGTH) {
        queued.push([json]);
        queuedLength = json.length;
      } else {
        queued.at(-1)!.push(json);
        queuedLength += json.length;
      }
      // During a burst, what answers its messages waits for them all; otherwise it goes when this task's microtasks do.
      if (first) {
        if (portTasks.length > 0) asTask(flush);
        else queueMicrotask(flush);
      }
    },
    disconnect() {
      if (closed) return;
      closed = true;
      flush();
      sending = sending.then(() => {
        if (!portId) return;
        externalPorts.delete(portId);
        gapCall('runtime', 'portDisconnect', { portId }, 0).catch(() => {});
      });
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

/** Past this many characters of JSON a port's messages go in another call: WebKit relays one long string slowly. */
const BATCH_LENGTH = 64 * 1024;

/** Names this context's ports to the extension's other contexts, which it posts on before Lilo answers. */
const portTag = Math.random().toString(36).slice(2);
let ports = 0;

/**
 * A port to the extension's other pages and worker, which Lilo relays as Chrome connects them: WebKit's drops one when a
 * process answers before the one that listens (WEBKIT-GAPS 60). With none to take it, Lilo disconnects it with lastError.
 */
function localPort(name: string): object {
  const portId = `${portTag}.${++ports}`;
  return externalPort(name, undefined, senderInfo().then((sender) => {
    gapCall('runtime', 'connect', { portId, name, ...sender }, 0).catch(() => {});
    return portId;
  }));
}

/** Whether runtime.sendMessage's `args` name another extension, which takes the message second. */
const toOtherExtension = (args: any[], runtime: any) => args.length >= 2 && typeof args[1] !== 'function' && otherExtension(args[0], runtime);

/** runtime.connect's `args`, which name another extension: Lilo relays the port to its onConnectExternal. */
function connectExternal(args: any[]): object {
  const name = typeof args[1]?.name === 'string' ? args[1].name : '';
  const opened = senderInfo().then((sender) => gapCall<string>('runtime', 'connectExternal', { id: args[0], name, ...sender }));
  return externalPort(name, undefined, opened);
}

/** runtime.sendMessage's `args`, which name another extension: Lilo relays the message to its onMessageExternal. */
function sendExternal(args: any[]): unknown {
  const callback = typeof args.at(-1) === 'function' ? args.at(-1) : undefined;
  // No timeout: the other extension may keep the channel open, as in Chrome.
  const sent = senderInfo().then((sender) => gapCall<{ response?: unknown }>('runtime', 'sendExternal', { id: args[0], message: args[1], ...sender }, 0));
  if (!callback) return sent.then((answer) => answer?.response);
  sent.then(
    (answer) => (answer && 'response' in answer ? callback(answer.response) : withLastError(portClosed, () => callback())),
    (error) => withLastError(error?.message ?? noReceiver, () => callback()),
  );
  return undefined;
}

/**
 * Chrome's port to an extension that has no onConnect listener anywhere: it posts until it disconnects, on the next
 * task, with lastError set. WebKit throws from connect instead (WEBKIT-GAPS 93).
 */
function unansweredPort(name: string): object {
  let closed = false;
  const port = {
    name,
    onMessage: new ChromeEvent<[unknown, unknown]>(),
    onDisconnect: new ChromeEvent<[unknown]>(),
    postMessage() {
      if (closed) throw new Error('Attempting to use a disconnected port object');
    },
    disconnect() { closed = true; },
  };
  setTimeout(() => {
    if (closed) return;
    closed = true;
    withLastError(noReceiver, () => port.onDisconnect.dispatch(port));
  });
  return port;
}

/** WebKit's connect, or Chrome's port when no context listens. */
function connectOrUnanswered(open: () => any, name: string): any {
  try {
    return open();
  } catch (error) {
    if (!String((error as Error)?.message).includes('No runtime.onConnect listeners found')) throw error;
    return unansweredPort(name);
  }
}

/**
 * chrome.runtime's connect and sendMessage, which Lilo relays to another extension's onConnectExternal and
 * onMessageExternal (WebKit has no cross-extension messaging); `sendLocal` sends the extension's own messages.
 */
export function crossExtensionMessaging(
  runtime: any,
  sendLocal: (...args: any[]) => any = (...args) => runtime.sendMessage(...args),
  ownOnConnect?: WrappedEvent<[any]>,
) {
  return {
    connect(...args: any[]) {
      if (otherExtension(args[0], runtime)) return connectExternal(args);
      // Chrome takes a null or undefined id before the connect info, as webext-redux passes it (Keeper).
      const [id, info] = typeof args[0] === 'string' ? args : [undefined, args.length > 1 && args[0] == null ? args[1] : args[0]];
      const name = typeof info?.name === 'string' ? info.name : '';
      // A content script has no channel to Lilo: its port is WebKit's.
      if (typeof runtime.connectNative === 'function') return localPort(name);
      const marked = { ...info, name: name + once };
      const open = () => (id === undefined ? runtime.connect(marked) : runtime.connect(id, marked));
      // WebKit disconnects the port when the first process answers with no receiver, as this context's own does
      // when it listens (WEBKIT-GAPS 60): it asks only the processes listening once the connect reaches it.
      return connectOrUnanswered(() => messagesOnce(ownOnConnect ? ownOnConnect.unheard(open) : open(), name), name);
    },
    sendMessage(...args: any[]) {
      return toOtherExtension(args, runtime) ? sendExternal(args) : sendLocal(...args);
    },
  };
}

/**
 * WebKit's own connect and sendMessage, which browser.runtime calls: another extension's id goes to Lilo's relay, and a
 * page's or the worker's port to Lilo, as chrome.runtime.connect's (webextension-polyfill uses this one).
 */
export const crossExtensionPatches: Record<string, Patch> = {
  connect: (original, self) => function (this: unknown, ...args: any[]) {
    const runtime: any = self(this);
    if (otherExtension(args[0], runtime)) return connectExternal(args);
    const info = typeof args[0] === 'string' || (args.length > 1 && args[0] == null) ? args[1] : args[0];
    const name = typeof info?.name === 'string' ? info.name : '';
    if (typeof runtime.connectNative === 'function') return localPort(name);
    return connectOrUnanswered(() => original.apply(runtime, args), name);
  },
  sendMessage: (original, self) => function (this: unknown, ...args: any[]) {
    return toOtherExtension(args, self(this)) ? sendExternal(args) : original.apply(self(this), args);
  },
};

/** A content script's tab, frame and url, its sender for another extension. */
const contentScript = (sender: any) => ({ url: sender.url, origin: sender.origin, tab: sender.tab, frameId: sender.frameId ?? 0 });

/**
 * The worker relays its content scripts' messages to another extension (message-answers.ts relayExternalMessaging),
 * through its own listener on WebKit's event, as the extension may not listen.
 */
export function relayForContentScripts(runtime: any): void {
  const add = Object.getPrototypeOf(runtime.onMessage).addListener;
  (add.__liloUnwrapped ?? add).call(runtime.onMessage, (message: any, sender: any, sendResponse: (answer: unknown) => void) => {
    const id = message?.liloExternal;
    if (typeof id !== 'string' || !sender?.tab) return undefined;
    gapCall('runtime', 'sendExternal', { id, message: message.message, ...contentScript(sender) }, 0)
      .then(sendResponse, (error) => sendResponse({ error: error?.message ?? noReceiver }));
    return true;
  });
}

const relayedPorts = new WeakSet<object>();

/** The worker relays a content script's port named `name` to another extension, `id`, once whatever listener sees it. */
function relayContentScriptPort(port: any, name: string, id: string): void {
  if (relayedPorts.has(port) || !port.sender?.tab) return;
  relayedPorts.add(port);
  const local: any = messagesOnce(port, name);
  const remote: any = externalPort(name, undefined, gapCall<string>('runtime', 'connectExternal', { id, name, ...contentScript(port.sender) }));
  local.onMessage.addListener((message: unknown) => remote.postMessage(message));
  remote.onMessage.addListener((message: unknown) => local.postMessage(message));
  local.onDisconnect.addListener(() => remote.disconnect());
  remote.onDisconnect.addListener(() => local.disconnect());
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
      // A worker hears every port until it reports its listeners: one it does not take fails, unless a page took it.
      if (listeners.length === 0) {
        gapCall('runtime', 'portDecline', { portId: info.portId }).catch(() => {});
        return;
      }
      const port = externalPort(info.name, info.sender, info.portId);
      // The port goes once the pages that took it are gone; a worker holds it until either end disconnects it.
      if (!isWorker) gapCall('runtime', 'portAccept', { portId: info.portId }).catch(() => {});
      for (const [listener] of listeners) {
        try { listener(port); } catch (err) { console.error(`Error in event handler: ${String(err)}`); }
      }
    },
  ),
});

