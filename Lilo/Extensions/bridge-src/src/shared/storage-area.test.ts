import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { installChromeCompat } from './chrome-compat.ts';

describe('chrome.storage areas', () => {
  /** An area sizing as WebKit does: the replaced value in UTF-16 bytes, the stored total in characters. */
  function area() {
    const stored = new Map<string, string>();
    const QUOTA_BYTES = 1000;
    const characters = () => [...stored].reduce((sum, [key, value]) => sum + key.length + value.length, 0);
    const bytes = (text: string) => (/[^\x00-\xff]/.test(text) ? 2 : 1) * text.length;
    const prototype = {
      QUOTA_BYTES,
      // As WebKit: it reads the keys `items` inherits too, and rejects a function at once.
      set(items: Record<string, unknown>) {
        const entries: Array<[string, unknown]> = [];
        for (const key in items) {
          if (typeof items[key] === 'function') throw new Error(`Invalid call to storageArea.set(). The 'items[\`${key}\`]' value is invalid, because it is not JSON-serializable.`);
          entries.push([key, items[key]]);
        }
        return this.store(entries);
      },
      async store(entries: Array<[string, unknown]>) {
        let size = BigInt(characters());
        for (const [key, value] of entries) {
          const old = stored.get(key);
          size += BigInt(bytes(key) + bytes(JSON.stringify(value))) - BigInt(old === undefined ? 0 : bytes(key) + bytes(old));
        }
        if (BigInt.asUintN(64, size) > QUOTA_BYTES) throw new Error('Invalid call to browser.storage.local.set(). Exceeded storage quota.');
        for (const [key, value] of entries) stored.set(key, JSON.stringify(value));
      },
      async get(keys: string[]) { return Object.fromEntries(keys.filter((key) => stored.has(key)).map((key) => [key, JSON.parse(stored.get(key)!)])); },
      async remove(keys: string[]) { keys.forEach((key) => stored.delete(key)); },
      async getBytesInUse() { return characters(); },
    };
    (globalThis as any).chrome = { runtime: { getManifest: () => ({}) }, storage: { local: Object.create(prototype) } };
    installChromeCompat({});
    return { local: (globalThis as any).chrome.storage.local, stored };
  }

  it('leaves out the non-finite numbers of objects, as Chrome does', async () => {
    const { local, stored } = area();
    await local.set({ entry: { expires: Infinity, n: NaN, kept: 1, list: [-Infinity, 2] }, top: Infinity });
    assert.equal(stored.get('entry'), '{"kept":1,"list":[null,2]}');
    assert.equal(stored.has('top'), false);
  });

  it('stores own keys without functions, as Chrome does, where WebKit reads inherited ones and rejects functions', async () => {
    const { local, stored } = area();
    (Object.prototype as any).clear = function () {};
    try {
      await local.set({ kept: 1, method() {}, nested: { f() {}, list: [() => 1, 2] } });
    } finally {
      delete (Object.prototype as any).clear;
    }
    assert.deepEqual([...stored.keys()], ['kept', 'nested']);
    assert.equal(stored.get('nested'), '{"list":[null,2]}');
    assert.equal(Object.getOwnPropertyDescriptor(Object.prototype, 'clear'), undefined);
  });

  it('leaves a cyclic value for WebKit to reject', async () => {
    const { local } = area();
    const cyclic: any = { n: NaN };
    cyclic.self = cyclic;
    await assert.rejects(local.set({ cyclic }), /circular|cyclic/i);
  });

  it('replaces a value outside Latin-1 that WebKit miscounts', async () => {
    const { local, stored } = area();
    await local.set({ key: String.fromCharCode(0x2019).repeat(300) });
    await local.set({ key: 'x' });
    assert.equal(stored.get('key'), '"x"');
  });

  it('still fails a set over the quota, keeping what was stored', async () => {
    const { local, stored } = area();
    await local.set({ key: String.fromCharCode(0x2019).repeat(300) });
    await assert.rejects(local.set({ key: 'x', other: 'y'.repeat(2000) }), /quota/);
    assert.equal(stored.get('key'), JSON.stringify(String.fromCharCode(0x2019).repeat(300)));
  });
});

// As WebKit's: a read answers from what is stored when it is made, a write stores a few ms later, and
// the methods are on a prototype every area shares.
class Area {
  stored: Record<string, unknown> = {};
  calls: string[] = [];
  get(keys: string | string[], callback?: (items: Record<string, unknown>) => void) {
    this.calls.push('get');
    const items = Object.fromEntries([keys].flat().filter((key) => key in this.stored).map((key) => [key, this.stored[key]]));
    if (callback) { queueMicrotask(() => callback(items)); return undefined; }
    return Promise.resolve(items);
  }
  set(items: Record<string, unknown>, callback?: () => void) {
    if (typeof items !== 'object') throw new TypeError('items must be an object');
    this.calls.push('set');
    if (Object.values(items).includes('unstorable')) return Promise.reject(new Error('Invalid value.'));
    return this.later(() => Object.assign(this.stored, items), callback);
  }
  remove(keys: string | string[], callback?: () => void) {
    this.calls.push('remove');
    return this.later(() => [keys].flat().forEach((key) => delete this.stored[key]), callback);
  }
  later(write: () => void, callback?: () => void) {
    const done = new Promise<void>((resolve) => setTimeout(() => { write(); resolve(); }, 5));
    if (callback) { done.then(callback); return undefined; }
    return done;
  }
}

function install(): { chrome: any; local: Area; sync: Area } {
  const [local, sync] = [new Area(), new Area()];
  (globalThis as any).chrome = { runtime: { getManifest: () => ({ permissions: ['storage'] }) }, storage: { local, sync } };
  installChromeCompat({});
  return { chrome: (globalThis as any).chrome, local, sync };
}

describe('storage areas', () => {
  it('answer a get after the set made before it, as Chrome', async () => {
    const { chrome } = install();
    chrome.storage.local.set({ a: 1 });
    assert.deepEqual(await chrome.storage.local.get('a'), { a: 1 });
    chrome.storage.local.set({ b: 2 }, () => {});
    assert.deepEqual(await new Promise((resolve) => chrome.storage.local.get('b', resolve)), { b: 2 });
  });

  it('keep the order of reads and writes made while a write is in flight', async () => {
    const { chrome } = install();
    chrome.storage.local.set({ a: 1 });
    const before = chrome.storage.local.get('a');
    chrome.storage.local.remove('a');
    const after = chrome.storage.local.get('a');
    assert.deepEqual(await before, { a: 1 });
    assert.deepEqual(await after, {});
  });

  it('call WebKit at once when no write is in flight, or for another area', () => {
    const { chrome, local, sync } = install();
    chrome.storage.local.get('a');
    chrome.storage.local.get('b');
    chrome.storage.local.set({ a: 1 });
    chrome.storage.sync.get('a');
    assert.deepEqual(local.calls, ['get', 'get', 'set']);
    assert.deepEqual(sync.calls, ['get']);
  });

  it('let WebKit throw for a write it rejects, and keep the area usable', async () => {
    const { chrome } = install();
    assert.throws(() => chrome.storage.local.set('a'), TypeError);
    assert.deepEqual(await chrome.storage.local.get('a'), {});
  });

  it('reach the areas browser shares', async () => {
    const { local } = install();
    local.set({ a: 1 });
    assert.deepEqual(await local.get('a'), { a: 1 });
  });

  it('make one call of the sets queued behind a write, each answered once it is stored', async () => {
    const { chrome, local } = install();
    const first = chrome.storage.local.set({ a: 1 });
    const queued = [2, 3, 4, 5].map((n) => chrome.storage.local.set({ [`k${n}`]: n }));
    const called = new Promise((resolve) => chrome.storage.local.set({ k6: 6 }, resolve));
    const read = chrome.storage.local.get(['a', 'k2', 'k6']);
    await Promise.all([first, ...queued, called]);
    assert.deepEqual(local.stored, { a: 1, k2: 2, k3: 3, k4: 4, k5: 5, k6: 6 });
    assert.deepEqual(await read, { a: 1, k2: 2, k6: 6 });
    assert.deepEqual(local.calls, ['set', 'set', 'get']);
  });

  it('keep a write queued after a read out of the writes before it', async () => {
    const { chrome, local } = install();
    chrome.storage.local.set({ a: 1 });
    chrome.storage.local.set({ b: 2 });
    const read = chrome.storage.local.get(['b', 'c']);
    chrome.storage.local.set({ c: 3 });
    assert.deepEqual(await read, { b: 2 });
    assert.deepEqual(await chrome.storage.local.get('c'), { c: 3 });
    assert.deepEqual(local.calls, ['set', 'set', 'get', 'set', 'get']);
  });

  it('apply queued sets of the same key one after the other', async () => {
    const { chrome, local } = install();
    chrome.storage.local.set({ a: 1 });
    chrome.storage.local.set({ a: 2 });
    await chrome.storage.local.set({ a: 3 });
    assert.equal(local.stored.a, 3);
    assert.deepEqual(local.calls, ['set', 'set', 'set']);
  });

  it('make one call of the removes queued behind a write', async () => {
    const { chrome, local } = install();
    local.stored = { a: 1, b: 2, c: 3, d: 4 };
    chrome.storage.local.set({ e: 5 });
    await Promise.all([chrome.storage.local.remove('a'), chrome.storage.local.remove(['b', 'c'])]);
    assert.deepEqual(local.stored, { d: 4, e: 5 });
    assert.deepEqual(local.calls, ['set', 'remove']);
  });

  it('answer each queued set on its own when their one call fails', async () => {
    const { chrome, local } = install();
    chrome.storage.local.set({ a: 1 });
    const fits = chrome.storage.local.set({ b: 2 });
    const over = chrome.storage.local.set({ c: 'unstorable' });
    const lastError = new Promise((resolve) => chrome.storage.local.set({ d: 'unstorable' }, () => resolve(chrome.runtime.lastError?.message)));
    const after = chrome.storage.local.set({ e: 5 });
    await fits;
    await assert.rejects(over, /Invalid value/);
    assert.equal(await lastError, 'Invalid value.');
    await after;
    assert.deepEqual(local.stored, { a: 1, b: 2, e: 5 });
    assert.deepEqual(local.calls, ['set', 'set', 'set', 'set', 'set', 'set']);
  });
});
