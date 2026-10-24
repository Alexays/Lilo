// WebKit sends nothing where Chrome answers null or sets lastError, so every context answers null for a valueless
// answer and a sender gets undefined only when no listener answered. SW-safe and content-script safe: chrome.* only.
import { bridgeChrome, withLastError } from './callbackify.ts';

type Listener = (message: unknown, sender: unknown, sendResponse: (response?: unknown) => void) => unknown;

/** What WebKit gets in place of each runtime.onMessage listener. */
const answering = new WeakMap<Listener, Listener>();

/**
 * What tabs.sendMessage sends again when nobody answered: a context that listens answers it, which tells a listener
 * that does not respond from no listener, two cases WebKit answers alike.
 */
export const listensProbe = { liloListens: true } as const;
const isProbe = (message: unknown) => (message as typeof listensProbe | undefined)?.liloListens === true;

function answeringListener(listener: Listener): Listener {
  let wrapper = answering.get(listener);
  if (!wrapper) {
    wrapper = function (this: unknown, message, sender, sendResponse) {
      if (isProbe(message)) return undefined;
      const result = listener.call(this, message, sender, (response?: unknown) => sendResponse(response === undefined ? null : response));
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
