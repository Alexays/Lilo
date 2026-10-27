// WebKit stalls a worker for good when it clones a CryptoKey into IndexedDB (WEBKIT-GAPS.md, gap 80). Its and its pages' keys
// keep their material, so IndexedDB stores that instead and reads give back a stand-in crypto.subtle resolves. SW-safe.

type Stored = {
  __liloCryptoKey: 1;
  type: string;
  extractable: boolean;
  algorithm: unknown;
  usages: string[];
  format: string;
  data: unknown;
};

type StoreScope = {
  CryptoKey?: abstract new () => object;
  crypto?: { subtle?: object };
  IDBObjectStore?: { prototype: Record<string, any> };
  IDBCursor?: { prototype: Record<string, any> };
  IDBRequest?: { prototype: object };
  IDBCursorWithValue?: { prototype: object };
};

const mark = '__liloCryptoKey';
const refused = 'Lilo: a CryptoKey nested this deep cannot be stored in IndexedDB from an extension worker, where WebKit '
  + 'would stall it (WEBKIT-GAPS.md, gap 80); an extension page can store it';

const isPlain = (value: object) => {
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === Array.prototype || prototype === null;
};
const isStored = (value: unknown): value is Stored => (value as Stored | null)?.[mark] === 1;

/** `inWorker`: a key nested deeper than a field fails there; a page stores it as WebKit does. */
export function installCryptoKeyStorage(scope: StoreScope, inWorker: boolean): void {
  const { CryptoKey } = scope;
  const subtle = scope.crypto?.subtle as Record<string, (...args: any[]) => Promise<any>> | undefined;
  if (!CryptoKey || !subtle) return;
  const subtlePrototype = Object.getPrototypeOf(subtle) as typeof subtle;
  const native = { ...Object.fromEntries(Object.getOwnPropertyNames(subtlePrototype).map((name) => [name, subtlePrototype[name]])) };

  // What each key, real or stand-in, stores as; a key missing here came from nowhere Lilo saw and stores as WebKit's.
  const storedOf = new WeakMap<object, Stored>();
  const standIns = new WeakMap<Stored, object>();
  const isStandIn = new WeakSet<object>();
  // Keys made extractable for their material that their caller asked not to be.
  const locked = new WeakSet<object>();
  // Each read gives new stand-ins: the real key is imported once per material, not once per read.
  const imported = new Map<string, Promise<object>>();
  const fingerprints = new WeakMap<Stored, string>();
  const revived = new WeakMap<object, unknown>();
  // No key yet means nothing to look for in a write: workers without WebCrypto keys pay nothing.
  let keys = 0;

  const lock = (key: any) => {
    locked.add(key);
    if (key.extractable) Object.defineProperty(key, 'extractable', { value: false });
  };
  const remember = (key: any, stored: Omit<Stored, typeof mark | 'type' | 'algorithm' | 'usages'>) => {
    storedOf.set(key, { [mark]: 1, type: key.type, algorithm: key.algorithm, usages: key.usages, ...stored });
    if (!stored.extractable) lock(key);
    keys++;
  };
  // A key made extractable for its material, which keeps the extractability its caller asked for.
  const adopt = async (subtle: object, key: any, extractable: boolean) => {
    extractable ||= key.type === 'public';
    for (const format of ['jwk', 'raw', 'pkcs8', 'spki']) {
      try {
        const data = await native.exportKey.call(subtle, format, key);
        return remember(key, { extractable, format, data });
      } catch { /* the next format */ }
    }
    if (!extractable) lock(key);
  };
  const adoptAll = async (subtle: object, result: any, extractable: boolean) => {
    if (result instanceof CryptoKey) await adopt(subtle, result, extractable);
    else if (result?.privateKey) await Promise.all([adopt(subtle, result.publicKey, true), adopt(subtle, result.privateKey, extractable)]);
    return result;
  };
  const standIn = (stored: Stored) => {
    let key = standIns.get(stored);
    if (!key) {
      key = Object.create(CryptoKey.prototype, {
        type: { value: stored.type }, extractable: { value: stored.extractable },
        algorithm: { value: stored.algorithm }, usages: { value: stored.usages },
      });
      storedOf.set(key!, stored);
      standIns.set(stored, key!);
      isStandIn.add(key!);
      keys++;
    }
    return key!;
  };
  const fingerprint = ({ format, data, extractable, usages, algorithm }: Stored) => {
    const material = data instanceof ArrayBuffer ? String.fromCharCode(...new Uint8Array(data)) : JSON.stringify(data);
    return JSON.stringify([format, extractable, usages, algorithm, material]);
  };
  // The real key behind a stand-in; anything else as given.
  const real = (subtle: object, value: any): any => {
    if (!isStandIn.has(value)) return value;
    const stored = storedOf.get(value)!;
    let id = fingerprints.get(stored);
    if (id === undefined) fingerprints.set(stored, id = fingerprint(stored));
    let key = imported.get(id);
    if (!key) {
      const load = (extractable: boolean) =>
        native.importKey.call(subtle, stored.format, stored.data, stored.algorithm, extractable, stored.usages);
      // PBKDF2 and HKDF keys cannot be extractable.
      key = load(true).catch(() => load(false)).then((key) => {
        storedOf.set(key, stored);
        if (!stored.extractable) lock(key);
        return key;
      });
      // A failed import is tried again on the next use.
      key.catch(() => imported.delete(id));
      imported.set(id, key);
    }
    return key;
  };
  const realAlgorithm = async (subtle: object, algorithm: any) =>
    algorithm?.public instanceof CryptoKey ? { ...algorithm, public: await real(subtle, algorithm.public) } : algorithm;
  const exportable = (key: object) => {
    if (locked.has(key) || storedOf.get(key)?.extractable === false) throw new DOMException('The key is not extractable', 'InvalidAccessError');
  };

  const wrap = (name: string, run: (this: object, ...args: any[]) => Promise<any>) => {
    if (typeof native[name] === 'function') subtlePrototype[name] = run;
  };
  for (const name of ['encrypt', 'decrypt', 'sign']) {
    wrap(name, async function (algorithm, key, data) {
      return native[name].call(this, await realAlgorithm(this, algorithm), await real(this, key), data);
    });
  }
  wrap('verify', async function (algorithm, key, signature, data) {
    return native.verify.call(this, algorithm, await real(this, key), signature, data);
  });
  wrap('deriveBits', async function (algorithm, baseKey, length) {
    return native.deriveBits.call(this, await realAlgorithm(this, algorithm), await real(this, baseKey), length);
  });
  wrap('exportKey', async function (format, key) {
    exportable(key);
    return native.exportKey.call(this, format, await real(this, key));
  });
  wrap('wrapKey', async function (format, key, wrappingKey, algorithm) {
    exportable(key);
    return native.wrapKey.call(this, format, await real(this, key), await real(this, wrappingKey), algorithm);
  });
  wrap('importKey', async function (format, keyData, algorithm, extractable, usages) {
    const key = await native.importKey.call(this, format, keyData, algorithm, extractable, usages);
    // The caller may reuse its buffer.
    const data = format === 'jwk' ? { ...keyData } : ArrayBuffer.isView(keyData)
      ? keyData.buffer.slice(keyData.byteOffset, keyData.byteOffset + keyData.byteLength) : keyData.slice(0);
    remember(key, { extractable, format, data });
    return key;
  });
  wrap('generateKey', async function (algorithm, extractable, usages) {
    let result;
    try { result = await native.generateKey.call(this, algorithm, true, usages); } catch {
      return native.generateKey.call(this, algorithm, extractable, usages);
    }
    return adoptAll(this, result, extractable);
  });
  wrap('deriveKey', async function (algorithm, baseKey, derivedAlgorithm, extractable, usages) {
    const args = [await realAlgorithm(this, algorithm), await real(this, baseKey), derivedAlgorithm] as const;
    let key;
    try { key = await native.deriveKey.call(this, ...args, true, usages); } catch {
      return native.deriveKey.call(this, ...args, extractable, usages);
    }
    return adoptAll(this, key, extractable);
  });
  wrap('unwrapKey', async function (format, wrappedKey, unwrappingKey, unwrapAlgorithm, unwrappedAlgorithm, extractable, usages) {
    const args = [format, wrappedKey, await real(this, unwrappingKey), unwrapAlgorithm, unwrappedAlgorithm] as const;
    let key;
    try { key = await native.unwrapKey.call(this, ...args, true, usages); } catch {
      return native.unwrapKey.call(this, ...args, extractable, usages);
    }
    return adoptAll(this, key, extractable);
  });

  // A key may be the stored value or one of its fields, as 2FAS (`put(key, id)`) and Keeper store theirs.
  const stored = (value: unknown) => {
    const found = value instanceof CryptoKey ? storedOf.get(value) : undefined;
    if (inWorker && value instanceof CryptoKey && !found) throw new DOMException(refused, 'DataCloneError');
    return found;
  };
  const storable = (value: unknown): unknown => {
    if (!keys || typeof value !== 'object' || value === null) return value;
    const own = stored(value);
    if (own) return own;
    let copy: any;
    if (isPlain(value)) {
      for (const [field, child] of Object.entries(value)) {
        const found = stored(child);
        if (found) (copy ??= Array.isArray(value) ? [...value] : { ...value })[field] = found;
      }
    }
    if (inWorker && holdsKey(copy ?? value)) throw new DOMException(refused, 'DataCloneError');
    return copy ?? value;
  };
  // Anything deeper would stall the worker. Binary data and strings, the bulk of what is stored, hold no key.
  const holdsKey = (value: object): boolean => {
    const pending: object[] = [value];
    const seen = new Set<object>();
    while (pending.length) {
      const item = pending.pop()!;
      if (seen.has(item)) continue;
      seen.add(item);
      if (item instanceof CryptoKey) return true;
      if (ArrayBuffer.isView(item) || item instanceof ArrayBuffer) continue;
      const children = item instanceof Map ? [...item.keys(), ...item.values()]
        : item instanceof Set ? [...item] : Object.values(item);
      for (const child of children) if (typeof child === 'object' && child !== null) pending.push(child);
    }
    return false;
  };
  for (const [prototype, method] of [[scope.IDBObjectStore?.prototype, 'put'], [scope.IDBObjectStore?.prototype, 'add'],
    [scope.IDBCursor?.prototype, 'update']] as const) {
    const write = prototype?.[method];
    if (typeof write !== 'function') continue;
    prototype![method] = function (this: unknown, value: unknown, ...rest: unknown[]) {
      return write.call(this, storable(value), ...rest);
    };
  }

  // Every read of every extension goes through here: a value without a key is handed back as is, with nothing
  // allocated. One with a key is copied once, so repeated reads of `result` give the same object.
  const revive = (value: unknown): unknown => {
    if (typeof value !== 'object' || value === null) return value;
    if (isStored(value)) return standIn(value);
    const known = revived.get(value);
    if (known) return known;
    let copy: any;
    if (Array.isArray(value)) {
      // getAll: the stored values are one level down.
      for (let index = 0; index < value.length; index++) {
        const next = revive(value[index]);
        if (next !== value[index]) (copy ??= value.slice())[index] = next;
      }
    } else if (isPlain(value)) {
      for (const field in value) {
        const child = (value as Record<string, unknown>)[field];
        if (isStored(child)) (copy ??= { ...value })[field] = standIn(child);
      }
    }
    if (copy) revived.set(value, copy);
    return copy ?? value;
  };
  for (const [prototype, property] of [[scope.IDBRequest?.prototype, 'result'], [scope.IDBCursorWithValue?.prototype, 'value']] as const) {
    const descriptor = prototype && Object.getOwnPropertyDescriptor(prototype, property);
    const read = descriptor?.get;
    if (!read) continue;
    Object.defineProperty(prototype, property, { ...descriptor, get(this: unknown) { return revive(read.call(this)); } });
  }
}
