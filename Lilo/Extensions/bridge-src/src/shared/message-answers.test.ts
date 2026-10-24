import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { answerAsChrome } from './message-answers.ts';
import { installChromeCompat } from './chrome-compat.ts';
import { mockGapAPI } from './ipc.testkit.ts';

// As WebKit's: listeners on a prototype every event shares, called with the sender's sendResponse.
class Event {
  listeners = new Set<(...args: any[]) => unknown>();
  addListener(listener: (...args: any[]) => unknown) { this.listeners.add(listener); }
  removeListener(listener: (...args: any[]) => unknown) { this.listeners.delete(listener); }
  hasListener(listener: (...args: any[]) => unknown) { return this.listeners.has(listener); }
  /** What the sender gets: the first answer, or undefined once every listener returned without one. */
  send(message: unknown): Promise<unknown> {
    return new Promise((resolve) => {
      let waits = false;
      for (const listener of this.listeners) {
        const result = listener(message, {}, resolve);
        if (result === true) waits = true;
        else if (typeof (result as Promise<unknown>)?.then === 'function') { waits = true; (result as Promise<unknown>).then(resolve); }
      }
      if (!waits) setTimeout(() => resolve(undefined), 0);
    });
  }
}

describe('runtime.onMessage listeners', () => {
  it('answer null where they answer no value, as Chrome', async () => {
    const onMessage = new Event();
    answerAsChrome(onMessage);
    onMessage.addListener((message: string, _sender: unknown, sendResponse: (response?: unknown) => void) => {
      if (message === 'empty') sendResponse();
      if (message === 'value') sendResponse(7);
      if (message === 'later') { setTimeout(() => sendResponse(), 1); return true; }
      if (message === 'promise') return Promise.resolve(undefined);
      return undefined;
    });
    assert.equal(await onMessage.send('empty'), null);
    assert.equal(await onMessage.send('value'), 7);
    assert.equal(await onMessage.send('later'), null);
    assert.equal(await onMessage.send('promise'), null);
    assert.equal(await onMessage.send('none'), undefined);
  });

  it('are removed and found as registered', () => {
    const onMessage = new Event();
    answerAsChrome(onMessage);
    const listener = () => undefined;
    onMessage.addListener(listener);
    assert.equal(onMessage.hasListener(listener), true);
    onMessage.removeListener(listener);
    assert.equal(onMessage.hasListener(listener), false);
    assert.equal(onMessage.listeners.size, 0);
  });
});

describe('sendMessage callbacks', () => {
  // WebKit calls back with undefined both when nothing answers and when it answers no value; each
  // context has its own prototypes.
  function install(page: boolean, answer: unknown): any {
    class Runtime {
      getManifest() { return { permissions: ['tabs'] }; }
      get lastError(): unknown { return null; }
      sendMessage(_message: unknown, callback?: (response: unknown) => void) {
        if (!callback) return Promise.resolve(answer);
        setTimeout(() => callback(answer), 0);
      }
    }
    class Tabs {
      sendMessage(_tabId: number, _message: unknown, callback: (response: unknown) => void) { setTimeout(() => callback(undefined), 0); }
    }
    (globalThis as any).chrome = { runtime: new Runtime(), tabs: new Tabs() };
    installChromeCompat({}, page);
    return (globalThis as any).chrome;
  }

  const outcome = (send: (callback: (response: unknown) => void) => void, chrome: any) =>
    new Promise((resolve) => send((response) => resolve([response, chrome.runtime.lastError?.message])));

  it("get Chrome's lastError when no listener answered", async () => {
    let workerListens = true;
    mockGapAPI(({ method }) => (method === 'workerListensToMessages' ? workerListens : null));
    const page = install(true, undefined);
    assert.deepEqual(await outcome((callback) => page.runtime.sendMessage(1, callback), page), [undefined, 'The message port closed before a response was received.']);
    workerListens = false;
    assert.deepEqual(await outcome((callback) => page.runtime.sendMessage(1, callback), page), [undefined, 'Could not establish connection. Receiving end does not exist.']);
    const worker = install(false, undefined);
    assert.deepEqual(await outcome((callback) => worker.runtime.sendMessage(1, callback), worker), [undefined, 'Could not establish connection. Receiving end does not exist.']);
    assert.deepEqual(await outcome((callback) => worker.tabs.sendMessage(3, 1, callback), worker), [undefined, 'Could not establish connection. Receiving end does not exist.']);
  });

  it('through browser.runtime, whose lastError stays WebKit\'s, get none', async () => {
    const chrome = install(false, undefined);
    const browserRuntime = Object.getPrototypeOf(chrome.runtime);
    assert.deepEqual(await outcome((callback) => browserRuntime.sendMessage.call(browserRuntime, 1, callback), chrome), [undefined, undefined]);
  });

  it('get no lastError for an answer without a value', async () => {
    const chrome = install(true, null);
    assert.deepEqual(await outcome((callback) => chrome.runtime.sendMessage(1, callback), chrome), [null, undefined]);
  });
});

describe('sendMessage promises of a page', () => {
  it("reject with Chrome's error when nothing receives, and resolve when the worker listens", async () => {
    let workerListens = false;
    mockGapAPI(({ method }) => (method === 'workerListensToMessages' ? workerListens : null));
    class Runtime {
      getManifest() { return {}; }
      get lastError(): unknown { return null; }
      sendMessage() { return Promise.resolve(undefined); }
    }
    (globalThis as any).chrome = { runtime: new Runtime() };
    installChromeCompat({}, true);
    const chrome = (globalThis as any).chrome;
    await assert.rejects(chrome.runtime.sendMessage(1), { message: 'Could not establish connection. Receiving end does not exist.' });
    workerListens = true;
    assert.equal(await chrome.runtime.sendMessage(1), undefined);
  });
});
