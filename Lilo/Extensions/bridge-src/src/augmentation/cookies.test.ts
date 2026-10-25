import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { cookiesOnChanged, cookiesPatches } from './cookies.ts';

describe('cookies.onChanged', () => {
  it('delivers changes in order with the store id WebKit reports', async () => {
    (globalThis as any).chrome = { cookies: { getAllCookieStores: async () => [{ id: 'store-1', tabIds: [] }] } };
    const heard: any[] = [];
    const two = new Promise<void>((resolve) => {
      cookiesOnChanged.addListener((info) => {
        heard.push(info);
        if (heard.length === 2) resolve();
      });
    });

    cookiesOnChanged.dispatch({ cookie: { name: 'a', value: '1' }, removed: true, cause: 'overwrite' });
    cookiesOnChanged.dispatch({ cookie: { name: 'a', value: '2' }, removed: false, cause: 'explicit' });
    await two;

    assert.deepEqual(heard.map((info) => [info.cookie.value, info.cookie.storeId, info.cause, info.removed]), [
      ['1', 'store-1', 'overwrite', true],
      ['2', 'store-1', 'explicit', false],
    ]);
  });
});

describe('cookies.set', () => {
  it('sets an https cookie secure once WebKit refuses it for lack of http access, as Chrome sets it', async () => {
    const calls: any[] = [];
    const webKitSet = async (details: any) => {
      calls.push(details);
      if (!details.secure && details.url.startsWith('https:')) throw new Error('Invalid call to cookies.set(). Host permissions are missing or not granted.');
      return { name: details.name, secure: !!details.secure };
    };
    const namespace = {};
    const set = cookiesPatches.set(webKitSet, () => namespace);

    assert.deepEqual(await set.call(namespace, { url: 'https://example.com/', name: 'a', value: '1' }), { name: 'a', secure: true });
    await assert.rejects(set.call(namespace, { url: 'https://example.com/', name: 'b', value: '1', secure: false }), /Host permissions/);
    assert.deepEqual(calls.map((details) => [details.name, details.secure]), [['a', undefined], ['a', true], ['b', false]]);
  });
});
