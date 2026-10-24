// WebKit answers a read before writes in flight, so calls wait for them. It also sizes a replaced non-Latin-1 value in
// UTF-16 bytes but the total in characters, failing the quota, so a set that fits is reapplied after removing its keys.
// It stores values as JSON, where Chrome leaves out non-finite numbers. A starting worker's reads answer once the
// events that woke it are dispatched, as Chrome's slower storage answers them (Custom Cursors' onInstalled sets
// the defaults its startup read finds missing).
import { callbackify } from './callbackify.ts';
import type { Patch } from './chrome-compat.ts';
import { workerStarting } from './ipc.ts';

/** Each storage area's writes in flight, as the promise that settles once they all have. */
const writesInFlight = new WeakMap<object, Promise<unknown>>();

function ordered(write: boolean): Patch {
  return (original, self) => function (this: unknown, ...args: any[]) {
    const area = self(this);
    const pending = writesInFlight.get(area);
    const starting = write ? undefined : workerStarting();
    if (!write && pending === undefined && !starting) return original.apply(this, args);
    const last = args.length - 1;
    const callback = typeof args[last] === 'function' ? args[last] : undefined;
    if (starting && callback) {
      args[last] = function (this: unknown, ...results: unknown[]) {
        starting.then(() => callback.apply(this, results));
      };
    }
    let call = () => original.apply(this, args);
    if (write && callback) {
      // runtime.lastError is set around the callback only, so the write ends when that runs.
      let ended!: () => void;
      const end = new Promise<void>((resolve) => { ended = resolve; });
      args[last] = function (this: unknown, ...results: unknown[]) {
        ended();
        return callback.apply(this, results);
      };
      call = () => { original.apply(this, args); return end; };
    }
    const result: Promise<unknown> = pending === undefined ? call() : pending.then(call);
    if (write) {
      const settled = result.then(() => {}, () => {});
      writesInFlight.set(area, settled);
      settled.then(() => { if (writesInFlight.get(area) === settled) writesInFlight.delete(area); });
    }
    if (callback) return undefined;
    return starting ? result.then((value) => starting.then(() => value)) : result;
  };
}

const read = ordered(false);
const write = ordered(true);

const setWithinQuota: Patch = (original, self) => function (this: unknown, items: any, callback?: () => void) {
  const area: any = self(this);
  // Called at once, so arguments WebKit rejects still throw.
  const first = original.call(area, items);
  return callbackify(async () => {
    try {
      return await first;
    } catch (error) {
      if (!/quota/i.test((error as Error)?.message) || items === null || typeof items !== 'object') throw error;
      const keys = Object.keys(items);
      // WebKit's own methods: the ordered ones would wait for this very set.
      const [used, old] = await Promise.all([area.getBytesInUse.__liloUnwrapped.call(area, null), area.get.__liloUnwrapped.call(area, keys)]);
      // WebKit's sizes: characters stored, at most two bytes per character set.
      const size = (entries: object, bytesPerCharacter: number) => Object.entries(entries)
        .reduce((sum, [key, value]) => sum + bytesPerCharacter * (key.length + (JSON.stringify(value)?.length ?? 0)), 0);
      if (used - size(old, 1) + size(items, 2) > area.QUOTA_BYTES) throw error;
      await area.remove.__liloUnwrapped.call(area, keys);
      try {
        return await original.call(area, items);
      } catch {
        await original.call(area, old);
        throw error;
      }
    }
  }, callback);
};

/**
 * `value` without the non-finite numbers of its objects, which Chrome leaves out and WebKit's JSON stores as null
 * (an array's stay: null in both). Copies only what changes; a cycle is left for WebKit to reject.
 */
function withoutNonFiniteNumbers(value: any, seen = new Set<object>()): any {
  if (typeof value !== 'object' || value === null || seen.has(value)) return value;
  seen.add(value);
  let copy: any;
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const next = withoutNonFiniteNumbers(value[i], seen);
      if (next !== value[i]) (copy ??= [...value])[i] = next;
    }
  } else {
    for (const key of Object.keys(value)) {
      const item = value[key];
      if (typeof item === 'number' && !Number.isFinite(item)) {
        copy ??= { ...value };
        delete copy[key];
        continue;
      }
      const next = withoutNonFiniteNumbers(item, seen);
      if (next !== item) (copy ??= { ...value })[key] = next;
    }
  }
  seen.delete(value);
  return copy ?? value;
}

export const storageAreaPatches: Record<string, Patch> = {
  get: read, getBytesInUse: read, getKeys: read, remove: write, clear: write,
  set: (original, self) => {
    const set = write(setWithinQuota(original, self), self);
    return function (this: unknown, items: any, ...rest: unknown[]) {
      return set.call(this, withoutNonFiniteNumbers(items), ...rest);
    };
  },
};
