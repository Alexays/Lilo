import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const answers: unknown[] = [];
const reports: unknown[] = [];
mockGapAPI((msg: any) => {
  if (msg.method === 'answerAuth') answers.push(msg.params);
  if (msg.namespace === 'events') reports.push({ [msg.method]: msg.params.events });
  return null;
});
(globalThis as any).chrome = { runtime: {} };

const { onAuthRequired, webRequestFrames } = await import('./webRequest.ts');

/** WebKit's onAuthRequired, which keeps the listener it gets. */
const webKit: any = Object.create({ addListener(this: any, listener: any) { this.listener = listener; }, removeListener() {} });
const event = onAuthRequired(() => webKit);
const challenge = { requestId: 'lilo-auth-1', url: 'https://example.com/a?b', type: 'main_frame', isProxy: true, challenger: { host: 'proxy.test', port: 3128 }, tab: null };
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('webRequest.onAuthRequired for a proxy challenge', () => {
  it("answers with an asyncBlocking listener's credentials", async () => {
    let heard: any;
    const listener = (details: any, callback?: unknown) => {
      heard = details;
      (callback as (response: unknown) => void)({ authCredentials: { username: 'u', password: 'p' } });
    };
    event.addListener(listener, { urls: ['<all_urls>'] }, ['asyncBlocking']);
    event.dispatch(challenge);
    await settle();
    event.removeListener(listener);

    assert.equal(heard.tabId, -1);
    assert.equal(heard.isProxy, true);
    assert.equal('tab' in heard, false);
    assert.deepEqual(answers.at(-1), { requestId: 'lilo-auth-1', credentials: { username: 'u', password: 'p' } });
  });

  it("cancels with a blocking listener's answer", async () => {
    const listener = () => ({ cancel: true });
    event.addListener(listener, { urls: ['*://*.example.com/*'] }, ['blocking']);
    event.dispatch(challenge);
    await settle();
    event.removeListener(listener);

    assert.deepEqual(answers.at(-1), { requestId: 'lilo-auth-1', cancel: true });
  });

  it('reports a listener that may answer apart, so Lilo waits for the contexts that have one only', async () => {
    reports.length = 0;
    const observer = () => {};
    const blocker = () => ({});
    event.addListener(observer, { urls: ['<all_urls>'] });
    event.addListener(blocker, { urls: ['<all_urls>'] }, ['blocking']);
    await settle();
    event.removeListener(blocker);
    event.removeListener(observer);

    assert.deepEqual(reports, [
      { listen: ['webRequest.onAuthRequired'] },
      { listen: ['webRequest.onAuthRequired.blocking'] },
      { unlisten: ['webRequest.onAuthRequired.blocking'] },
      { unlisten: ['webRequest.onAuthRequired'] },
    ]);
  });

  it('never answers from a context whose listeners only observe', async () => {
    const count = answers.length;
    let heard = false;
    const observer = () => { heard = true; return { cancel: true }; };
    event.addListener(observer, { urls: ['<all_urls>'] });
    event.dispatch(challenge);
    await settle();
    event.removeListener(observer);

    assert.equal(heard, true);
    assert.equal(answers.length, count);
  });

  it('answers empty when its blocking listeners leave the request out, while observers only observe', async () => {
    const elsewhere = () => ({ cancel: true });
    const observer = () => ({ cancel: true });
    event.addListener(elsewhere, { urls: ['https://other.test/*'] }, ['blocking']);
    event.addListener(observer, { urls: ['<all_urls>'] });
    event.dispatch(challenge);
    await settle();
    event.removeListener(elsewhere);
    event.removeListener(observer);

    assert.deepEqual(answers.at(-1), { requestId: 'lilo-auth-1' });
  });

  it("leaves the challenge to other contexts when this one has no listener, and gives WebKit's own events a callback", async () => {
    const count = answers.length;
    event.dispatch(challenge);
    await settle();
    assert.equal(answers.length, count);

    let callback: unknown;
    event.addListener((_details: unknown, received: unknown) => { callback = received; }, { urls: ['<all_urls>'] }, ['asyncBlocking']);
    webKit.listener({ url: 'https://example.com/' });
    assert.equal(typeof callback, 'function');
  });
});

describe("webRequest details with Chrome's frames", () => {
  /** WebKit's event, which keeps its listener and filter. */
  const webKitEvent = () => Object.create({ addListener(this: any, listener: any, filter: any) { this.listener = listener; this.filter = filter; }, removeListener(this: any) { this.listener = undefined; } });
  const page = { tabId: 7, frameId: 0, parentFrameId: -1, type: 'main_frame', url: 'https://a.example/' };
  const frame = { tabId: 7, frameId: 38654705665, parentFrameId: 4294967300, type: 'main_frame', url: 'https://ads.example/' };

  it('reports a subframe document as sub_frame, its main frame parent as 0', () => {
    const native = webKitEvent();
    const { onBeforeRequest } = webRequestFrames(() => native);
    const heard: any[] = [];
    onBeforeRequest.addListener((details: any) => heard.push(details), { urls: ['<all_urls>'] });
    native.listener(page);
    native.listener(frame);
    native.listener({ ...frame, frameId: 51539607553, parentFrameId: frame.frameId });
    native.listener({ ...frame, type: 'image', parentFrameId: 4294967300 });
    assert.deepEqual(heard.map((details) => [details.type, details.parentFrameId]), [['main_frame', -1], ['sub_frame', 0], ['sub_frame', frame.frameId], ['image', 0]]);
    assert.equal(heard[0], page, 'a main frame request is WebKit\'s');
  });

  it('matches a filter on frame types after the fix', () => {
    const native = webKitEvent();
    const { onCompleted } = webRequestFrames(() => native);
    const heard: string[] = [];
    const listener = (details: any) => heard.push(details.type);
    onCompleted.addListener(listener, { urls: ['<all_urls>'], types: ['sub_frame'] });
    assert.deepEqual(native.filter.types, ['sub_frame', 'main_frame'], 'WebKit names subframe documents main_frame');
    native.listener(page);
    native.listener(frame);
    assert.deepEqual(heard, ['sub_frame']);
    assert.equal(onCompleted.hasListener(listener), true);
    onCompleted.removeListener(listener);
    assert.equal(native.listener, undefined);
  });
});
