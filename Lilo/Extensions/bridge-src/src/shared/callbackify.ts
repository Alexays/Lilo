// WebKit ignores any redefinition of its runtime.lastError (WEBKIT-GAPS.md, gap 3): the view of
// chrome.runtime that chrome-compat.ts hands out serves this one while a Lilo callback runs.
let lastError: { message: string } | undefined;
let lastErrorRead = false;

/** The runtime.lastError of the Lilo callback running, if any; reading it checks it, as in Chrome. */
export function liloLastError(): { message: string } | undefined {
  if (lastError !== undefined) lastErrorRead = true;
  return lastError;
}

/** The message of the Lilo callback's runtime.lastError, without checking it. */
export function liloLastErrorMessage(): string | undefined {
  return lastError?.message;
}

/**
 * Runs `callback` with `message` as chrome.runtime.lastError, then logs it as Chrome does when the
 * callback did not read it.
 */
export function withLastError(message: string, callback: () => void): void {
  // Nested in another's callback, it stands for the outer lastError, which holds again after it but logs no more.
  const outer = lastError;
  lastError = { message };
  lastErrorRead = false;
  try {
    callback();
  } finally {
    if (!lastErrorRead) console.error(`Unchecked runtime.lastError: ${message}`);
    lastError = outer;
    lastErrorRead = true;
  }
}

// An extension may put its own wrapper in globalThis.chrome (Proton Pass's answers undefined for
// everything): Lilo calls through the chrome it installed instead.
let installedChrome: any;

/** Makes `chrome` globalThis.chrome and the chrome Lilo calls through, whatever an extension assigns later. */
export function installBridgeChrome(chrome: any): void {
  installedChrome = chrome;
  (globalThis as any).chrome = chrome;
}

/** The chrome Lilo calls through: the one it installed, else the global one (content scripts). */
export function bridgeChrome(): any {
  return installedChrome ?? (globalThis as any).chrome;
}

/** Logs a callback's exception in Chrome's words: V8 prefixes a thrown non-Error with "Uncaught". */
function reportCallbackError(error: unknown): void {
  // One string: WebKit reports only the first argument of a console.error.
  console.error(`Error handling response: ${error instanceof Error ? '' : 'Uncaught '}${String(error)}`);
}

/**
 * Chrome's dual callback/Promise pattern: with a callback, an error goes to chrome.runtime.lastError and the callback
 * gets undefined, and runs with the global object as `this`. An exception thrown from a callback is logged, as Chrome does.
 */
export function callbackify<T>(
  impl: () => Promise<T>,
  callback?: (result: T) => void
): Promise<T> | undefined {
  const promise = impl();
  if (callback) {
    promise.then((result: T) => {
      try { callback.call(globalThis, result); } catch (error) { reportCallbackError(error); }
    }, (err: unknown) => {
      try {
        withLastError(err instanceof Error ? err.message : String(err), () => callback.call(globalThis, undefined as unknown as T));
      } catch (error) { reportCallbackError(error); }
    });
    return undefined;
  }
  return promise;
}
