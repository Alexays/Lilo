import { describe, it, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { installPageWorkerMessages, installWorkerClientMessages } from './worker-messages.ts';

class WindowClient {}

const channels: BroadcastChannel[] = [];
class Channel extends BroadcastChannel {
  constructor(name: string) { super(name); channels.push(this); }
}

function page(href: string) {
  const sent: unknown[] = [];
  class ServiceWorker {
    scriptURL: string;
    constructor(scriptURL: string) { this.scriptURL = scriptURL; }
    postMessage(data: unknown) { sent.push(data); }
  }
  const url = new URL(href);
  const scope = {
    ServiceWorker, BroadcastChannel: Channel, MessageEvent, crypto,
    location: { protocol: url.protocol, host: url.host, href },
    navigator: { serviceWorker: new EventTarget() },
  };
  installPageWorkerMessages(scope);
  return { scope, sent, worker: (script: string) => new ServiceWorker(script) };
}

function worker() {
  const scope = Object.assign(new EventTarget(), { BroadcastChannel: Channel, WindowClient, MessageEvent });
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

  it('leaves another origin\'s worker to the native postMessage', () => {
    const offscreen = page('chrome-extension://abc/offscreen.html');
    offscreen.worker('https://example.com/sw.js').postMessage('hi');
    assert.deepEqual(offscreen.sent, ['hi']);
  });
});
