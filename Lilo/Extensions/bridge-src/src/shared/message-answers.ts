// WebKit sends nothing where Chrome answers null or sets lastError, so every context answers null for a valueless
// answer and a sender gets undefined only when no listener answered. SW-safe and content-script safe: chrome.* only.
import { bridgeChrome, withLastError } from './callbackify.ts';
import { ChromeEvent } from './chrome-event.ts';
import { home } from './static-compat.ts';

type Listener = (message: unknown, sender: unknown, sendResponse: (response?: unknown) => void) => unknown;

/** What WebKit gets in place of each runtime.onMessage listener. */
const answering = new WeakMap<Listener, Listener>();

/**
 * What tabs.sendMessage sends again when nobody answered: a context that listens answers it, which tells a listener
 * that does not respond from no listener, two cases WebKit answers alike.
 */
export const listensProbe = { liloListens: true } as const;
const isProbe = (message: unknown) => (message as typeof listensProbe | undefined)?.liloListens === true;
/** A content script's message to another extension, which only the worker's relay hears (runtime.ts). */
const isExternal = (message: unknown) => typeof (message as { liloExternal?: unknown } | undefined)?.liloExternal === 'string';

let workerScript: string | undefined;

/**
 * WebKit names the worker by its extension's origin alone, where Chrome gives its script's url: Aircall's offscreen
 * document answers only a sender whose url names its background script.
 */
function chromeSender(sender: any): unknown {
  if (typeof sender?.url !== 'string' || sender.url !== sender.origin || sender.tab) return sender;
  if (workerScript === undefined) {
    const background = bridgeChrome()?.runtime?.getManifest?.()?.background;
    workerScript = String(background?.lilo_service_worker ?? background?.service_worker ?? '');
  }
  return workerScript ? { ...sender, url: new URL(workerScript, `${sender.origin}/`).href } : sender;
}

function answeringListener(listener: Listener): Listener {
  let wrapper = answering.get(listener);
  if (!wrapper) {
    wrapper = function (this: unknown, message, sender, sendResponse) {
      if (isProbe(message) || isExternal(message)) return undefined;
      const result = listener.call(this, message, chromeSender(sender), (response?: unknown) => sendResponse(response === undefined ? null : response));
      return typeof (result as PromiseLike<unknown>)?.then === 'function'
        ? Promise.resolve(result).then((response) => (response === undefined ? null : response))
        : result;
    };
    answering.set(listener, wrapper);
  }
  return wrapper;
}

/**
 * Registers `onMessage`'s listeners through answeringListener, calling `onListen` for each, and answers the probe
 * while one is registered. The members go on the event object, which the caller keeps alive: WebKit shares the
 * prototype with every other event.
 */
export function answerAsChrome(onMessage: any, onListen?: () => void): void {
  // Each content script entry carries its own copy of the compat: the first one answers for all.
  if (Object.hasOwn(onMessage, 'addListener')) return;
  const listeners = new Set<Listener>();
  const answerProbe = (message: unknown, _sender: unknown, sendResponse: (response: boolean) => void) => {
    if (isProbe(message)) sendResponse(true);
  };
  for (const name of ['addListener', 'removeListener', 'hasListener']) {
    Object.defineProperty(onMessage, name, {
      value(listener: Listener, ...rest: unknown[]) {
        if (name === 'addListener') onListen?.();
        // The prototype's at call time: Lilo patches it once the namespace is handed out.
        const prototype = Object.getPrototypeOf(onMessage);
        const result = prototype[name].call(onMessage, typeof listener === 'function' ? answeringListener(listener) : listener, ...rest);
        if (typeof listener === 'function' && name !== 'hasListener') {
          const listened = listeners.size > 0;
          if (name === 'addListener') listeners.add(listener);
          else listeners.delete(listener);
          if (listened !== listeners.size > 0) prototype[listened ? 'removeListener' : 'addListener'].call(onMessage, answerProbe);
        }
        return result;
      },
      configurable: true, writable: true,
    });
  }
}

const noReceiver = 'Could not establish connection. Receiving end does not exist.';

/**
 * WebKit answers alike when no listener exists and when listeners do not respond, so `noAnswer`, called with the
 * message's arguments, picks Chrome's runtime.lastError for the case; with `rejects`, the promise fails as Chrome's
 * when nothing receives.
 */
export function lastErrorWithoutAnswer(
  send: (...args: any[]) => any,
  noAnswer: (this: unknown, ...args: any[]) => string | Promise<string>,
  rejects = false,
): (...args: any[]) => any {
  return function (this: unknown, ...args: any[]) {
    const last = args.length - 1;
    const callback = args[last];
    const self = this;
    if (typeof callback === 'function') {
      const sent = args.slice(0, last);
      args[last] = function (this: unknown, response?: unknown) {
        if (response !== undefined || bridgeChrome()?.runtime?.lastError) return callback.call(this, response);
        Promise.resolve(noAnswer.apply(self, sent)).then((message) => withLastError(message, () => callback.call(this)));
      };
      return send.apply(this, args);
    }
    const result = send.apply(this, args);
    if (!rejects || typeof result?.then !== 'function') return result;
    return result.then(async (response: unknown) => {
      if (response === undefined && await noAnswer.apply(self, args) === noReceiver) throw new Error(noReceiver);
      return response;
    });
  };
}

// Ends the name of a port Lilo opens whose both ends are Lilo's: only such a port carries numbered messages,
// which a port of browser.runtime would not read.
export const once = '?lilo';
const served = new WeakMap<object, object>();

/**
 * WebKit delivers each message posted before the port connects twice or more (gap 43), so each carries its sender
 * and number and a repeat is dropped; a message the extension repeats gets a new number. On a port both of whose
 * ends number theirs, `numberedOnly` drops any other message: another port sharing its channel id posted it (gap 89).
 */
export function messagesOnce(port: any, name: string, numberedOnly = false): object {
  const known = served.get(port);
  if (known) return known;
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
    if (from === undefined) return numberedOnly ? undefined : chromePort.onMessage.dispatch(numbered, chromePort);
    if (number <= (received.get(from) ?? 0)) return;
    received.set(from, number);
    chromePort.onMessage.dispatch(numbered.message, chromePort);
  });
  // Synchronous: WebKit's runtime.lastError holds while it runs.
  port.onDisconnect.addListener(() => chromePort.onDisconnect.dispatch(chromePort));
  served.set(port, chromePort);
  return chromePort;
}

// Chrome's ids, and Lilo's for an unpacked extension without a manifest key.
export const otherExtension = (id: unknown, runtime: any) => typeof id === 'string' && /^([a-p]{32}|extension-[0-9a-f]{16})$/.test(id) && id !== runtime.id;
/** Ends, before `once`, the name of a port a content script opens to another extension, with that extension's id. */
export const externalMark = '?liloExternal=';

/**
 * A content script's runtime.sendMessage and connect to another extension, which WebKit lacks: they go to the
 * extension's worker, which relays them (runtime.ts relayForContentScripts). A content script's runtime.lastError
 * stays WebKit's, so a callback learns of no failure.
 */
export function relayExternalMessaging(runtime: any): void {
  const target = home(runtime);
  const { sendMessage, connect } = target;
  // Each content script entry carries its own copy of the compat: the first one relays for all.
  if (typeof sendMessage !== 'function' || typeof connect !== 'function' || sendMessage.__liloRelays) return;
  const relayed = function (this: unknown, ...args: any[]) {
    if (args.length < 2 || typeof args[1] === 'function' || !otherExtension(args[0], runtime)) return sendMessage.apply(this, args);
    const callback = typeof args.at(-1) === 'function' ? args.at(-1) : undefined;
    const sent = Promise.resolve(sendMessage.call(runtime, { liloExternal: args[0], message: args[1] })).then((answer: any) => {
      if (!answer || 'error' in answer) throw new Error(answer?.error ?? noReceiver);
      return answer.response;
    });
    if (!callback) return sent;
    sent.then((response) => callback(response), () => callback());
    return undefined;
  };
  Object.defineProperty(target, 'sendMessage', { value: Object.assign(relayed, { __liloRelays: true }), configurable: true, writable: true });
  Object.defineProperty(target, 'connect', {
    value(this: unknown, ...args: any[]) {
      if (!otherExtension(args[0], runtime)) return connect.apply(this, args);
      const name = typeof args[1]?.name === 'string' ? args[1].name : '';
      return messagesOnce(connect.call(runtime, { name: `${name}${externalMark}${args[0]}${once}` }), name, true);
    },
    configurable: true, writable: true,
  });
}
