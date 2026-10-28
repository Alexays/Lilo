import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { answerAsChrome, frameMark, listensProbe, messagesOnce, relayExternalMessaging } from './message-answers.ts';
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
  // First: the worker's script is read once per context.
  it("hear the worker's message from its script's url, as Chrome, where WebKit gives its origin", () => {
    (globalThis as any).chrome = {
      runtime: { getManifest: () => ({ background: { service_worker: 'js/lilo-background-wrapper.js', lilo_service_worker: 'js/sw.js' } }) },
    };
    const onMessage = new Event();
    answerAsChrome(onMessage);
    const heard: unknown[] = [];
    onMessage.addListener((_message: unknown, sender: unknown) => { heard.push(sender); });
    const origin = 'chrome-extension://abc';
    const page = { id: 'abc', url: `${origin}/popup.html`, origin };
    const tab = { id: 'abc', url: origin, origin, tab: { id: 1 } };
    for (const sender of [{ id: 'abc', url: origin, origin }, page, tab]) {
      for (const listener of onMessage.listeners) listener('hi', sender, () => {});
    }
    assert.deepEqual(heard, [{ id: 'abc', url: `${origin}/js/sw.js`, origin }, page, tab]);
  });

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

  it('answer the probe of tabs.sendMessage while one is registered, without hearing it', async () => {
    const onMessage = new Event();
    answerAsChrome(onMessage);
    const heard: unknown[] = [];
    const listener = (message: unknown) => { heard.push(message); };
    assert.equal(await onMessage.send(listensProbe), undefined);
    onMessage.addListener(listener);
    assert.equal(await onMessage.send(listensProbe), true);
    onMessage.removeListener(listener);
    assert.equal(await onMessage.send(listensProbe), undefined);
    assert.deepEqual(heard, []);
  });

  it("leave a content script's message to another extension to the worker's relay", async () => {
    const onMessage = new Event();
    answerAsChrome(onMessage);
    const heard: unknown[] = [];
    onMessage.addListener((message: unknown) => { heard.push(message); });
    assert.equal(await onMessage.send({ liloExternal: 'abcdefghijklmnopabcdefghijklmnop', message: 1 }), undefined);
    assert.deepEqual(heard, []);
  });

  it("hear a frame's message its extension page sends for it from the frame's url, as Chrome", () => {
    const onMessage = new Event();
    answerAsChrome(onMessage);
    const heard: unknown[] = [];
    onMessage.addListener((message: unknown, sender: unknown) => { heard.push([message, sender]); });
    const page = { id: 'abc', url: 'chrome-extension://abc/offscreen.html', origin: 'chrome-extension://abc' };
    for (const listener of onMessage.listeners) listener({ liloFrame: 'https://example.com/frame.html', message: 'ping' }, page, () => {});
    assert.deepEqual(heard, [['ping', { id: 'abc', url: 'https://example.com/frame.html', origin: 'https://example.com' }]]);
  });

  it("leave a content script's message naming a frame as it is: a web page could name any sender", () => {
    const onMessage = new Event();
    answerAsChrome(onMessage);
    const heard: unknown[] = [];
    onMessage.addListener((message: unknown, sender: unknown) => { heard.push([message, sender]); });
    const content = { id: 'abc', url: 'https://evil.example/', origin: 'https://evil.example', tab: { id: 3 } };
    const forged = { liloFrame: 'https://bank.example/login', message: 'fill' };
    for (const listener of onMessage.listeners) listener(forged, content, () => {});
    assert.deepEqual(heard, [[forged, content]]);
  });
});

describe('a port a frame opens through its extension page', () => {
  it("takes its own name and the frame's url as its sender", () => {
    const event = () => ({ addListener() {} });
    const url = 'https://example.com/frame.html?q=a?liloTab=x';
    const port: any = messagesOnce({
      sender: { id: 'abc', url: 'chrome-extension://abc/offscreen.html', origin: 'chrome-extension://abc' },
      onMessage: event(), onDisconnect: event(), postMessage() {}, disconnect() {},
    }, `name?liloFrame=x${frameMark}${encodeURIComponent(url)}`);
    assert.equal(port.name, 'name?liloFrame=x');
    assert.deepEqual(port.sender, { id: 'abc', url, origin: 'https://example.com' });
  });

  it("keeps a content script's port name and sender as they are", () => {
    const event = () => ({ addListener() {} });
    const sender = { id: 'abc', url: 'https://evil.example/', origin: 'https://evil.example', tab: { id: 3 } };
    const name = `x${frameMark}${encodeURIComponent('https://bank.example/')}`;
    const port: any = messagesOnce({ sender, onMessage: event(), onDisconnect: event(), postMessage() {}, disconnect() {} }, name);
    assert.equal(port.name, name);
    assert.equal(port.sender, sender);
  });
});

let contentListens = false;
const probes: unknown[] = [];
const lateMessages: unknown[] = [];

// WebKit calls back with undefined both when nothing answers and when it answers no value; each
// context has its own prototypes.
function install(page: boolean, answer: unknown): any {
  class Runtime {
    getManifest() { return { permissions: ['tabs'] }; }
    getURL(path: string) { return `chrome-extension://abc/${path}`; }
    get lastError(): unknown { return null; }
    sendMessage(_message: unknown, callback?: (response: unknown) => void) {
      if (!callback) return Promise.resolve(answer);
      setTimeout(() => callback(answer), 0);
    }
  }
  // The tab's content scripts listen, without responding, when the probe is answered.
  class Tabs {
    get(tabId: number) {
      if (tabId === 6) return Promise.resolve({ id: 6, status: 'loading', url: 'https://example.com/' });
      return Promise.resolve({ id: tabId, status: tabId === 4 ? 'loading' : 'complete', url: tabId >= 4 ? 'chrome-extension://abc/popup.html' : 'https://example.com/' });
    }
    sendMessage(tabId: number, message: unknown, ...rest: unknown[]) {
      const callback = typeof rest[rest.length - 1] === 'function' ? rest.pop() as (response: unknown) => void : undefined;
      probes.push(rest[0]);
      // Tab 6's content script starts listening once its third probe came: it then answers the message.
      if (tabId === 6) lateMessages.push(message);
      const late = tabId === 6 && lateMessages.filter((sent) => sent === listensProbe).length >= 3;
      const response = message === listensProbe ? (contentListens || late) || undefined : late ? 'pong' : undefined;
      if (!callback) return Promise.resolve(response);
      setTimeout(() => callback(response), 0);
    }
  }
  (globalThis as any).chrome = { runtime: new Runtime(), tabs: new Tabs() };
  installChromeCompat({}, page);
  return (globalThis as any).chrome;
}

describe('sendMessage callbacks', () => {
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
    contentListens = true;
    assert.deepEqual(await outcome((callback) => worker.tabs.sendMessage(3, 1, { frameId: 2 }, callback), worker), [undefined, 'The message port closed before a response was received.']);
    assert.deepEqual(probes.slice(-1), [{ frameId: 2 }], 'the probe goes to the frame the message went to');
    contentListens = false;
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

describe('tabs.sendMessage promises', () => {
  it("reach the content script of a loading tab that listens a moment after the message, as Chrome's do", async () => {
    const worker = install(false, undefined);
    lateMessages.length = 0;
    assert.equal(await worker.tabs.sendMessage(6, 'ping'), 'pong');
    assert.deepEqual(lateMessages.filter((sent) => sent !== listensProbe), ['ping', 'ping'], 'the message goes again once, after nobody received it');
  });

  it("reject with Chrome's error when no content script listens, and resolve when one does", async () => {
    const worker = install(false, undefined);
    await assert.rejects(worker.tabs.sendMessage(3, 1), { message: 'Could not establish connection. Receiving end does not exist.' });
    contentListens = true;
    assert.equal(await worker.tabs.sendMessage(3, 1), undefined);
    contentListens = false;
  });

  it("resolve for a tab still loading one of the extension's pages, which cannot listen yet", async () => {
    const worker = install(false, undefined);
    assert.equal(await worker.tabs.sendMessage(4, 1), undefined);
    await assert.rejects(worker.tabs.sendMessage(5, 1), { message: 'Could not establish connection. Receiving end does not exist.' }, 'a loaded page that does not listen');
  });

  it('reject for the sending page\'s own tab, still loading, which Chrome never delivers to', async () => {
    const page = install(true, undefined);
    const scope = globalThis as any;
    const saved = { top: scope.top, location: scope.location };
    Object.assign(scope, { top: scope, location: { href: 'chrome-extension://abc/popup.html#home' } });
    try {
      await assert.rejects(page.tabs.sendMessage(4, 1), { message: 'Could not establish connection. Receiving end does not exist.' });
    } finally {
      Object.assign(scope, saved);
    }
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

  it('resolve when another page, as an offscreen document, listens without answering', async () => {
    mockGapAPI(({ method }) => (method === 'workerListensToMessages' ? false : null));
    let pageListens = false;
    class Runtime {
      getManifest() { return {}; }
      get lastError(): unknown { return null; }
      sendMessage(message: unknown) { return Promise.resolve(pageListens && (message as typeof listensProbe)?.liloListens ? true : undefined); }
    }
    (globalThis as any).chrome = { runtime: new Runtime() };
    installChromeCompat({}, true);
    const chrome = (globalThis as any).chrome;
    await assert.rejects(chrome.runtime.sendMessage(1), { message: 'Could not establish connection. Receiving end does not exist.' });
    pageListens = true;
    assert.equal(await chrome.runtime.sendMessage(1), undefined);
  });
});

describe("a content script's messages to another extension", () => {
  const other = 'abcdefghijklmnopabcdefghijklmnop';
  // WebKit's content script runtime, its methods on the prototype; `answer` is the worker relay's.
  function contentRuntime(answer: unknown) {
    const sent: unknown[] = [];
    const opened: unknown[] = [];
    const runtime = Object.create({
      sendMessage(message: unknown) { sent.push(message); return Promise.resolve(answer); },
      connect(info: { name: string }) {
        opened.push(info);
        return { name: info.name, onMessage: { addListener() {} }, onDisconnect: { addListener() {} }, postMessage() {}, disconnect() {} };
      },
    });
    runtime.id = 'ponmlkjihgfedcbaponmlkjihgfedcba';
    relayExternalMessaging(runtime);
    return { runtime, sent, opened };
  }

  it("go to the worker's relay and resolve with the other extension's answer", async () => {
    const { runtime, sent } = contentRuntime({ response: 'pong' });
    assert.equal(await runtime.sendMessage(other, 'ping'), 'pong');
    assert.equal(await new Promise((resolve) => runtime.sendMessage(other, 'ping', {}, resolve)), 'pong');
    assert.deepEqual(await runtime.sendMessage('own'), { response: 'pong' }, "the extension's own message goes as it is");
    assert.deepEqual(sent, [{ liloExternal: other, message: 'ping' }, { liloExternal: other, message: 'ping' }, 'own']);
  });

  it("reject with Chrome's error when nothing receives, and resolve undefined without an answer", async () => {
    const noReceiver = 'Could not establish connection. Receiving end does not exist.';
    await assert.rejects(contentRuntime({ error: noReceiver }).runtime.sendMessage(other, 1), { message: noReceiver });
    await assert.rejects(contentRuntime(undefined).runtime.sendMessage(other, 1), { message: noReceiver }, 'the extension has no worker to relay it');
    assert.equal(await contentRuntime({ closed: true }).runtime.sendMessage(other, 1), undefined);
  });

  it('open a port the worker relays, named for the other extension', () => {
    const { runtime, opened } = contentRuntime(undefined);
    const port = runtime.connect(other, { name: 'tunnel' });
    runtime.connect({ name: 'own' });
    assert.equal(port.name, 'tunnel');
    assert.deepEqual(opened, [{ name: `tunnel?liloExternal=${other}?lilo` }, { name: 'own' }]);
  });
});

describe("WebKit's ports", () => {
  it("fail in Chrome's words once disconnected, through Lilo's wrapper or not", () => {
    class Port {
      name = 'state';
      onMessage = { addListener() {} };
      onDisconnect = { addListener() {} };
      postMessage() { throw new Error('Invalid call to port.postMessage(). The port is disconnected.'); }
    }
    const port = new Port();
    const wrapped: any = messagesOnce(port, 'state');
    assert.throws(() => wrapped.postMessage('late'), { message: 'Attempting to use a disconnected port object' });
    assert.throws(() => new Port().postMessage(), { message: 'Attempting to use a disconnected port object' }, 'every port of its prototype');
  });
});
