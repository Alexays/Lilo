import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { installCryptoKeyStorage } from './crypto-key-storage.ts';

class IDBObjectStore {
  written: unknown[] = [];
  put(value: unknown) { this.written.push(value); }
}

// A file of its own: an install wraps the process's crypto.subtle for good.
describe('installCryptoKeyStorage in an extension page', () => {
  installCryptoKeyStorage({ CryptoKey, crypto, IDBObjectStore }, false);

  it('stores a key nested deeper than a field as WebKit does, and one in a field as the worker reads it', async () => {
    const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['encrypt']);
    const store = new IDBObjectStore();
    const nested = { keys: { gcm: key } };
    store.put(nested);
    store.put({ id: 'k', value: key });
    assert.equal(store.written[0], nested);
    assert.equal((store.written[1] as { value: { __liloCryptoKey: number } }).value.__liloCryptoKey, 1);
  });
});
