import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { acceptFrameMessaging, relayFrameMessaging } from './frame-messaging.ts';
import { ChromeEvent } from './chrome-event.ts';
import { frameMark, listensProbe } from './message-answers.ts';

const key = 'a'.repeat(64);
const origin = 'chrome-extension://abc';
const frameUrl = 'https://example.com/frame.html';

const until = async (done: () => boolean) => {
  for (let tries = 0; !done(); tries++) {
    assert.ok(tries < 100, 'timed out');
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
};

/** The extension page at the top of the frame, its chrome.runtime's members `runtime`, serving `served` as its key. */
function extensionPage(runtime: Record<string, unknown>, served = key) {
  const listeners: ((event: any) => void)[] = [];
  const stopped: unknown[] = [];
  const page: any = {
    addEventListener(type: string, listener: (event: any) => void) { if (type === 'message') listeners.push(listener); },
    fetch: async (url: string) => ({ ok: url === `${origin}/_lilo/frame-key`, text: async () => served }),
    postMessage(data: unknown, targetOrigin: string, ports: unknown[] = []) {
      assert.equal(targetOrigin, origin, 'the request goes to the extension page alone');
      const event = { data: structuredClone(data), ports, stopImmediatePropagation() { stopped.push(data); } };
      setTimeout(() => { for (const listener of listeners) listener(event); }, 0);
    },
  };
  page.top = page;
  (globalThis as any).chrome = { runtime: { getURL: (path: string) => `${origin}/${path}`, ...runtime } };
  acceptFrameMessaging(page);
  return { page, stopped };
}

/** WebKit's runtime of a content script in a frame of `top`, its methods `webKit`, refusing messages for want of a tab. */
function frame(top: unknown, { webKit = {}, ancestor = origin, frameKey = key }: { webKit?: object; ancestor?: string; frameKey?: string } = {}) {
  const runtime = Object.create({
    sendMessage: () => Promise.reject(new Error('Tab not found.')),
    connect: () => assert.fail("WebKit's connect"),
    ...webKit,
  });
  runtime.id = 'abc';
  runtime.getURL = (path: string) => `${origin}/${path}`;
  relayFrameMessaging({ top, location: { href: frameUrl, ancestorOrigins: [ancestor] }, MessageChannel, addEventListener() {} }, runtime, frameKey);
  return runtime;
}

describe("a content script of a frame no tab shows, such as an offscreen document's", () => {
  it('sends its messages through the extension page at the top, which hears them first', async () => {
    const sent: unknown[] = [];
    const { page, stopped } = extensionPage({ sendMessage: async (message: unknown) => { sent.push(message); return 'pong'; } });
    const runtime = frame(page);
    assert.equal(await new Promise((resolve) => runtime.sendMessage('ping', resolve)), 'pong');
    assert.equal(await runtime.sendMessage('abc', 'again'), 'pong');
    assert.deepEqual(sent, [{ liloFrame: frameUrl, message: 'ping' }, { liloFrame: frameUrl, message: 'again' }]);
    assert.equal(stopped.length, 2, "the extension page's own listeners never see a request");
  });

  it("rejects with the extension page's error", async () => {
    const { page } = extensionPage({ sendMessage: () => Promise.reject(new Error('Could not establish connection. Receiving end does not exist.')) });
    await assert.rejects(frame(page).sendMessage('ping'), { message: 'Could not establish connection. Receiving end does not exist.' });
  });

  it('is not heard without the extension\'s key, which a web page cannot show', async () => {
    const sent: unknown[] = [];
    const { page, stopped } = extensionPage({ sendMessage: async (message: unknown) => { sent.push(message); return 'pong'; } });
    let answered = false;
    frame(page, { frameKey: 'b'.repeat(64) }).sendMessage('forged').then(() => { answered = true; });
    await until(() => stopped.length === 1);
    await new Promise((resolve) => setTimeout(resolve, 5));
    assert.deepEqual(sent, []);
    assert.equal(answered, false);
  });

  it('opens its ports through the extension page, with what it posted before', async () => {
    const remote = {
      onMessage: new ChromeEvent<[unknown]>(),
      onDisconnect: new ChromeEvent<[]>(),
      posted: [] as unknown[],
      disconnected: false,
      postMessage(message: unknown) { this.posted.push(message); },
      disconnect() { this.disconnected = true; },
    };
    const opened: unknown[] = [];
    const { page } = extensionPage({ connect: (info: unknown) => { opened.push(info); return remote; } });
    const port = frame(page).connect({ name: 'channel' });
    assert.equal(port.name, 'channel');
    port.postMessage(1);
    const heard: unknown[] = [];
    port.onMessage.addListener((message: unknown) => heard.push(message));
    await until(() => remote.posted.length === 1);
    assert.deepEqual(opened, [{ name: `channel${frameMark}${encodeURIComponent(frameUrl)}` }]);
    assert.deepEqual(remote.posted, [1]);
    remote.onMessage.dispatch(2);
    await until(() => heard.length === 1);
    assert.deepEqual(heard, [2]);
    port.disconnect();
    await until(() => remote.disconnected);
  });

  it('learns when the other end disconnects', async () => {
    const remote = { onMessage: new ChromeEvent<[unknown]>(), onDisconnect: new ChromeEvent<[]>(), postMessage() {}, disconnect() {} };
    const { page } = extensionPage({ connect: () => remote });
    const port = frame(page).connect();
    let disconnected = false;
    port.onDisconnect.addListener(() => { disconnected = true; });
    await new Promise((resolve) => setTimeout(resolve, 5));
    remote.onDisconnect.dispatch();
    await until(() => disconnected);
    assert.throws(() => port.postMessage(1), { message: 'Attempting to use a disconnected port object' });
  });
});

describe('a content script WebKit lets message', () => {
  it('keeps WebKit\'s messaging where a tab shows the extension page', async () => {
    const calls: unknown[] = [];
    const runtime = frame({}, { webKit: { sendMessage: (...args: unknown[]) => { calls.push(args); return Promise.resolve(true); } } });
    assert.equal(await runtime.sendMessage('ping'), true);
    assert.deepEqual(calls, [[listensProbe], ['ping']]);
  });

  it("is left as it is in a frame of another extension's page or a web page", () => {
    const sendMessage = () => Promise.resolve();
    for (const ancestor of ['chrome-extension://other', 'https://example.com']) {
      const runtime = frame({}, { webKit: { sendMessage }, ancestor });
      assert.equal(runtime.sendMessage, sendMessage);
    }
  });

  it('is left as it is when the preparer wrote no key', () => {
    const sendMessage = () => Promise.resolve();
    assert.equal(frame({}, { webKit: { sendMessage }, frameKey: '__LILO_FRAME_KEY__' }).sendMessage, sendMessage);
  });
});
