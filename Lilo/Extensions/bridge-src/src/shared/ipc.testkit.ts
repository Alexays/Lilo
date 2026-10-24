// Stands in for Lilo's channel in bridge tests. The latest mock answers every call, as ipc.ts keeps the port it
// opened first; `respond` runs synchronously, like the post it stands for.
import assert from 'node:assert/strict';

type Call = { namespace: string; method: string; params: any };

let respond: (call: Call) => unknown = () => null;
const portListeners: Array<(message: unknown) => void> = [];

/** Lilo pushes `envelope` on the channel, which a gap call or listener opened. */
export function pushGapEvent(envelope: { namespace: string; event: string; args?: unknown[] }): void {
  pushToChannel(envelope);
}

/** Lilo pushes `message` on the channel as it is, as it pushes a state. */
export function pushToChannel(message: object): void {
  assert.ok(portListeners.length > 0, 'no channel is open');
  portListeners.forEach((listener) => listener(message));
}

export function mockGapAPI(respondWith: (call: Call) => unknown): void {
  respond = respondWith;
  const connectNative = () => {
    const listeners: Array<(message: unknown) => void> = [];
    return {
      onMessage: {
        addListener: (listener: (message: unknown) => void) => {
          listeners.push(listener);
          portListeners.push(listener);
        },
      },
      onDisconnect: { addListener() {} },
      postMessage(message: any) {
        if (typeof message?.id !== 'number') return;
        new Promise((resolve) => resolve(respond({ namespace: message.namespace, method: message.method, params: message.params })))
          .then(
            (result) => listeners.forEach((listener) => listener({ reply: message.id, result })),
            (error) => listeners.forEach((listener) => listener({ reply: message.id, error: String(error?.message ?? error) })),
          );
      },
    };
  };
  const inject = (chrome: any) => {
    if (!chrome) return;
    chrome.runtime ??= {};
    // A wrapper answering nothing, as Proton Pass's, keeps no runtime.
    if (chrome.runtime) chrome.runtime.connectNative ??= connectNative;
  };
  let current = (globalThis as any).chrome ?? {};
  inject(current);
  Object.defineProperty(globalThis, 'chrome', {
    configurable: true,
    get: () => current,
    set: (value) => { inject(value); current = value; },
  });
}
