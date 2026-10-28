import { describe, it, before, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { installCryptoKeyStorage } from './crypto-key-storage.ts';

// IndexedDB as far as the worker sees it: writes clone the value, reads hand it back through `result` and `value`.
class IDBRequest {
  #result: unknown;
  constructor(result: unknown) { this.#result = result; }
  get result() { return this.#result; }
}
class IDBCursor {
  updated: unknown[] = [];
  update(value: unknown) { this.updated.push(structuredClone(value)); return new IDBRequest(undefined); }
}
class IDBCursorWithValue extends IDBCursor {
  #value: unknown;
  constructor(value: unknown) { super(); this.#value = value; }
  get value() { return this.#value; }
}
class IDBObjectStore {
  data = new Map<unknown, unknown>();
  written: unknown[] = [];
  put(value: unknown, key: unknown) { this.written.push(value); this.data.set(key, structuredClone(value)); return new IDBRequest(key); }
  add(value: unknown, key: unknown) { return this.put(value, key); }
  get(key: unknown) { return new IDBRequest(structuredClone(this.data.get(key))); }
  getAll() { return new IDBRequest([...this.data.values()].map((value) => structuredClone(value))); }
}

const subtle = crypto.subtle;
const iv = new Uint8Array(12);
const plain = new TextEncoder().encode('vault');
const holdsCryptoKey = (value: unknown): boolean => value instanceof CryptoKey
  || (typeof value === 'object' && value !== null && Object.values(value).some(holdsCryptoKey));

describe('installCryptoKeyStorage', () => {
  let store: IDBObjectStore;
  before(() => installCryptoKeyStorage({ CryptoKey, crypto, IDBObjectStore, IDBCursor, IDBRequest, IDBCursorWithValue }, true));
  beforeEach(() => { store = new IDBObjectStore(); });

  it('stores a key as its material and reads back a stand-in crypto.subtle uses as the key', async () => {
    const key = await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    assert.equal(key.extractable, false);
    await assert.rejects(subtle.exportKey('raw', key), { name: 'InvalidAccessError' });

    store.put(key, 'data_gcm');
    assert.equal(holdsCryptoKey(store.data.get('data_gcm')), false);
    const request = store.get('data_gcm');
    const read = request.result as CryptoKey;
    assert.equal(request.result, read);
    assert.ok(read instanceof CryptoKey);
    assert.deepEqual([read.type, read.extractable, read.usages, (read.algorithm as AesKeyAlgorithm).length], ['secret', false, ['encrypt', 'decrypt'], 256]);
    await assert.rejects(subtle.exportKey('raw', read), { name: 'InvalidAccessError' });
    const sealed = await subtle.encrypt({ name: 'AES-GCM', iv }, read, plain);
    assert.deepEqual(new Uint8Array(await subtle.decrypt({ name: 'AES-GCM', iv }, key, sealed)), plain);
  });

  it('keeps an unwrapped key as its caller asked, as Keeper unwraps its vault keys', async () => {
    const wrapping = await subtle.generateKey({ name: 'AES-KW', length: 256 }, false, ['wrapKey', 'unwrapKey']);
    const original = await subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
    const wrapped = await subtle.wrapKey('raw', original, wrapping, 'AES-KW');
    store.put(wrapping, 'wrapping');
    const unwrapping = store.get('wrapping').result as CryptoKey;
    const key = await subtle.unwrapKey('raw', wrapped, unwrapping, 'AES-KW', 'AES-GCM', false, ['encrypt', 'decrypt']);
    assert.equal(key.extractable, false);
    await assert.rejects(subtle.wrapKey('raw', key, wrapping, 'AES-KW'), { name: 'InvalidAccessError' });

    store.put({ id: 'k', value: key }, 'k');
    const [, { value }] = store.getAll().result as [CryptoKey, { value: CryptoKey }];
    const sealed = await subtle.encrypt({ name: 'AES-GCM', iv }, original, plain);
    assert.deepEqual(new Uint8Array(await subtle.decrypt({ name: 'AES-GCM', iv }, value, sealed)), plain);
  });

  it('signs with an imported private key read back, as 2FAS stores its signing key', async () => {
    const pair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pkcs8 = new Uint8Array(await subtle.exportKey('pkcs8', pair.privateKey));
    const key = await subtle.importKey('pkcs8', pkcs8, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    pkcs8.fill(0);
    store.put(key, 'signingPrivateKey');
    const read = store.get('signingPrivateKey').result as CryptoKey;
    const algorithm = { name: 'ECDSA', hash: 'SHA-256' };
    assert.ok(await subtle.verify(algorithm, pair.publicKey, await subtle.sign(algorithm, read, plain), plain));
  });

  it('derives the same bits from a PBKDF2 key read back, which cannot be extractable', async () => {
    const key = await subtle.importKey('raw', new TextEncoder().encode('password'), 'PBKDF2', false, ['deriveBits']);
    const cursor = new IDBCursorWithValue(undefined);
    cursor.update({ key });
    const read = (new IDBCursorWithValue(cursor.updated[0]).value as { key: CryptoKey }).key;
    const derive = (base: CryptoKey) => subtle.deriveBits({ name: 'PBKDF2', salt: iv, iterations: 1000, hash: 'SHA-256' }, base, 256);
    assert.deepEqual(new Uint8Array(await derive(read)), new Uint8Array(await derive(key)));
  });

  it('exports an extractable key read back as the original', async () => {
    const key = await subtle.generateKey({ name: 'HMAC', hash: 'SHA-256' }, true, ['sign']);
    store.put(key, 'hmac');
    const read = store.get('hmac').result as CryptoKey;
    assert.deepEqual(await subtle.exportKey('jwk', read), await subtle.exportKey('jwk', key));
  });

  it('refuses a key nested deeper than a field, which WebKit would stall on', async () => {
    const key = await subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['encrypt']);
    assert.throws(() => store.put({ keys: { gcm: key } }, 'nested'), { name: 'DataCloneError' });
    assert.equal(store.data.size, 0);
  });

  it('writes and reads anything else as given', () => {
    const value = { id: 1, bytes: new Uint8Array([1, 2]), nested: [{ a: 'b' }] };
    store.put(value, 'plain');
    assert.equal(store.written[0], value);
    const request = store.get('plain');
    assert.deepEqual(request.result, value);
    assert.equal(request.result, request.result);
  });
});
