import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const answers: unknown[] = [];
mockGapAPI((msg: any) => {
  if (msg.method === 'answerAuth') answers.push(msg.params);
  return null;
});
(globalThis as any).chrome = { runtime: {} };

const { onAuthRequired } = await import('./webRequest.ts');

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

  it('answers nothing for listeners whose filter leaves the request out, or that only observe', async () => {
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
