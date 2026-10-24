// Chrome on a Mac never fires onSuspend/onSuspendCanceled on a worker, onRestartRequired/restart outside ChromeOS
// kiosks, nor onConnectNative without a native host, which Lilo never starts. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify, withLastError } from '../shared/callbackify.ts';
import { ChromeEvent, WrappedEvent } from '../shared/chrome-event.ts';
import { GapChromeEvent } from '../shared/gap-event.ts';

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

// Ends the name of a port chrome.runtime.connect opens, whose both ends are then Lilo's: only such a
// port carries numbered messages, which a port of browser.runtime would not read.
const once = '?lilo';
const served = new WeakMap<object, object>();

/**
 * WebKit delivers each message posted before the port connects twice or more (gap 43), so each carries its sender
 * and number and a repeat is dropped; a message the extension repeats gets a new number.
 */
function messagesOnce(port: any, name: string): object {
  const sender = Math.random();
  let sent = 0;
  const received = new Map<number, number>();
  const chromePort = {
    name,
    sender: port.sender,
    onMessage: new ChromeEvent<[unknown, unknown]>(),
    onDisconnect: new ChromeEvent<[unknown]>(),
    postMessage: (message: unknown) => port.postMessage({ [once]: [sender, ++sent], message }),
    disconnect: () => port.disconnect(),
  };
  port.onMessage.addListener((numbered: any) => {
    // A context that kept WebKit's port posts its messages as they are.
    const [from, number] = numbered?.[once] ?? [];
    if (from === undefined) return chromePort.onMessage.dispatch(numbered, chromePort);
    if (number <= (received.get(from) ?? 0)) return;
    received.set(from, number);
    chromePort.onMessage.dispatch(numbered.message, chromePort);
  });
  // Synchronous: WebKit's runtime.lastError holds while it runs.
  port.onDisconnect.addListener(() => chromePort.onDisconnect.dispatch(chromePort));
  served.set(port, chromePort);
  return chromePort;
}

/** WebKit's runtime.onConnect, `source`, handing out the port chrome.runtime.connect opened as messagesOnce's. */
export const onConnect = (source: () => object) => new WrappedEvent<[any]>(source, (listener) => (port: any) => listener(
  typeof port?.name === 'string' && port.name.endsWith(once) ? served.get(port) ?? messagesOnce(port, port.name.slice(0, -once.length)) : port,
));

const otherExtension = (id: unknown, runtime: any) => typeof id === 'string' && /^[a-p]{32}$/.test(id) && id !== runtime.id;

/**
 * chrome.runtime's connect and sendMessage to another extension as Chrome's to one not installed:
 * WebKit has no cross-extension messaging and throws, or reports an extension error.
 */
export function crossExtensionMessaging(runtime: any) {
  return {
    connect(...args: any[]) {
      if (!otherExtension(args[0], runtime)) {
        const [id, info] = typeof args[0] === 'string' ? args : [undefined, args[0]];
        const name = typeof info?.name === 'string' ? info.name : '';
        const marked = { ...info, name: name + once };
        return messagesOnce(id === undefined ? runtime.connect(marked) : runtime.connect(id, marked), name);
      }
      const port = {
        name: typeof args[1]?.name === 'string' ? args[1].name : '',
        sender: undefined,
        onMessage: new ChromeEvent<[unknown, unknown]>(),
        onDisconnect: new ChromeEvent<[unknown]>(),
        postMessage(_message: unknown) {},
        disconnect() {},
      };
      setTimeout(() => withLastError(noReceiver, () => port.onDisconnect.dispatch(port)), 0);
      return port;
    },
    sendMessage(...args: any[]) {
      if (args.length < 2 || typeof args[1] === 'function' || !otherExtension(args[0], runtime)) return runtime.sendMessage(...args);
      const callback = args.at(-1);
      if (typeof callback !== 'function') return Promise.reject(new Error(noReceiver));
      setTimeout(() => withLastError(noReceiver, () => callback()), 0);
      return undefined;
    },
  };
}
