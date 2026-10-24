import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { cookiesOnChanged } from './cookies.ts';

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
