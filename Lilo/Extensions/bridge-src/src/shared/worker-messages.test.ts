import { describe, it, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { installPageWorkerMessages, installWorkerClientMessages } from './worker-messages.ts';

class WindowClient {}

// As WebKit's: waitUntil throws on an event a script builds.
class ExtendableMessageEvent extends MessageEvent<unknown> {
  waitUntil(_promise: Promise<unknown>) { throw new DOMException('Event is not trusted', 'InvalidStateError'); }
}

const channels: Channel[] = [];
class Channel extends BroadcastChannel {
  listeners = 0;
  constructor(name: string) { super(name); channels.push(this); }
  override addEventListener(...args: Parameters<BroadcastChannel['addEventListener']>) { this.listeners++; super.addEventListener(...args); }
}

function page(href: string, registrations: unknown[] = []) {
  const sent: unknown[] = [];
  class ServiceWorker {
    scriptURL: string;
    constructor(scriptURL: string) { this.scriptURL = scriptURL; }
    postMessage(data: unknown, ..._transfer: unknown[]) { sent.push(data); }
  }
  const url = new URL(href);
  const scope = {
    ServiceWorker, BroadcastChannel: Channel, MessageEvent, MessagePort, crypto,
    location: { protocol: url.protocol, host: url.host, href },
    navigator: { serviceWorker: Object.assign(new EventTarget(), { getRegistrations: async () => registrations }) },
    chrome: { runtime: { getManifest: () => ({ background: { service_worker: 'background/worker.js' } }) } },
    setTimeout,
  };
  installPageWorkerMessages(scope);
  return { scope, sent, worker: (script: string) => new ServiceWorker(script) };
}

function worker() {
  const scope = Object.assign(new EventTarget(), { BroadcastChannel: Channel, WindowClient, MessageEvent, ExtendableMessageEvent, MessageChannel, crypto });
  installWorkerClientMessages(scope);
  return scope;
}

const next = (target: EventTarget) => new Promise<MessageEvent>((resolve) => target.addEventListener('message', (e) => resolve(e as MessageEvent), { once: true }));

describe('worker messages', () => {
  // Node keeps a process alive while a BroadcastChannel is open.
  afterEach(() => { for (const channel of channels.splice(0)) channel.close(); });

  it('carries a page message to its worker and the answer back to that page only', async () => {
    const sw = worker();
    const offscreen = page('chrome-extension://abc/offscreen.html');
    const popup = page('chrome-extension://abc/popup.html');
    const popupAnswers: unknown[] = [];
    popup.scope.navigator.serviceWorker.addEventListener('message', (e) => popupAnswers.push((e as MessageEvent).data));

    const received = next(sw);
    offscreen.worker('chrome-extension://abc/lilo-background-wrapper.js').postMessage({ event: 'connected' });
    const message = await received;
    assert.deepEqual(message.data, { event: 'connected' });
    assert.ok(message.source instanceof WindowClient);
    assert.equal((message.source as any).url, 'chrome-extension://abc/offscreen.html');

    const answered = next(offscreen.scope.navigator.serviceWorker);
    (message.source as any).postMessage({ ok: true });
    assert.deepEqual((await answered).data, { ok: true });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(popupAnswers, []);
    assert.deepEqual(offscreen.sent, []);
  });

  it('gives the worker an event whose waitUntil takes the handler\'s promise', async () => {
    const sw = worker();
    const offscreen = page('chrome-extension://abc/offscreen.html');
    const handled = new Promise<ExtendableMessageEvent>((resolve) => sw.addEventListener('message', (e) => {
      (e as ExtendableMessageEvent).waitUntil(Promise.reject(new Error('handled')));
      resolve(e as ExtendableMessageEvent);
    }, { once: true }));
    offscreen.worker('chrome-extension://abc/lilo-background-wrapper.js').postMessage('hi');
    const message = await handled;
    assert.ok(message instanceof ExtendableMessageEvent);
    assert.deepEqual(message.ports, []);
  });

  it('hands the worker a port the page transferred, which answers on the page\'s own port', async () => {
    const sw = worker();
    const offscreen = page('chrome-extension://abc/offscreen.html');
    const { port1, port2 } = new MessageChannel();
    const received = next(sw);
    offscreen.worker('chrome-extension://abc/lilo-background-wrapper.js').postMessage({ id: 1 }, [port2]);
    const message = await received;
    assert.equal(message.ports.length, 1);
    const answered = new Promise((resolve) => { port1.onmessage = ({ data }) => resolve(data); });
    message.ports[0].postMessage({ id: 1, result: 'done' });
    assert.deepEqual(await answered, { id: 1, result: 'done' });
    const asked = new Promise((resolve) => { message.ports[0].onmessage = ({ data }) => resolve(data); });
    port1.postMessage('again');
    assert.equal(await asked, 'again');
    port1.close();
    message.ports[0].close();
  });

  it('relays every transferred port through one listener per context', async () => {
    const sw = worker();
    const offscreen = page('chrome-extension://abc/offscreen.html');
    const before = channels.map((channel) => channel.listeners);
    for (let i = 0; i < 3; i++) {
      const { port2 } = new MessageChannel();
      const received = next(sw);
      offscreen.worker('chrome-extension://abc/lilo-background-wrapper.js').postMessage({ id: i }, [port2]);
      for (const port of (await received).ports) port.close();
      port2.close();
    }
    const added = channels.map((channel, i) => channel.listeners - (before[i] ?? 0));
    assert.deepEqual(added, [1, 1]);
  });

  it('resolves ready with the registration a page finds', async () => {
    const registration = { active: { scriptURL: 'chrome-extension://abc/background/lilo-background-wrapper.js' } };
    const offscreen = page('chrome-extension://abc/offscreen.html', [{ active: { scriptURL: 'https://example.com/sw.js' } }, registration]);
    assert.equal(await (offscreen.scope.navigator.serviceWorker as any).ready, registration);
  });

  it('resolves ready with a stand-in carrying the messages once the worker answers a page that finds no registration', async () => {
    const offscreen = page('chrome-extension://abc/offscreen.html');
    const pending = (offscreen.scope.navigator.serviceWorker as any).ready;
    await new Promise((resolve) => setTimeout(resolve, 150));
    const sw = worker();
    const { active } = await pending;
    assert.equal(active.scriptURL, 'chrome-extension://abc/background/worker.js');
    const received = next(sw);
    active.postMessage({ event: 'connected' });
    assert.deepEqual((await received).data, { event: 'connected' });
    assert.deepEqual(offscreen.sent, []);
  });

  it('leaves another origin\'s worker to the native postMessage', () => {
    const offscreen = page('chrome-extension://abc/offscreen.html');
    offscreen.worker('https://example.com/sw.js').postMessage('hi');
    assert.deepEqual(offscreen.sent, ['hi']);
  });
});
