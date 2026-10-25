// WebKit answers a read before writes in flight, so calls wait for them; the writes queued meanwhile go as one. It also sizes a replaced non-Latin-1 value in
// UTF-16 bytes but the total in characters, failing the quota, so a set that fits is reapplied after removing its keys.
// It stores values as JSON, where Chrome leaves out non-finite numbers and functions. A starting worker's reads answer once the
// events that woke it are dispatched, as Chrome's slower storage answers them (Custom Cursors' onInstalled sets
// the defaults its startup read finds missing). WebKit can settle several answers in one task, before the code awaiting the
// first runs on, where Chrome answers each in a task of its own (Markdown Reader's popup mounts before its preferences load).
import { callbackify } from './callbackify.ts';
import type { Patch } from './chrome-compat.ts';
import { workerStarting } from './ipc.ts';

/** Each storage area's writes in flight, as the promise that settles once they all have. */
const writesInFlight = new WeakMap<object, Promise<unknown>>();

function inFlight(area: object, write: Promise<unknown>): void {
  const settled = write.then(() => {}, () => {});
  writesInFlight.set(area, settled);
  settled.then(() => { if (writesInFlight.get(area) === settled) writesInFlight.delete(area); });
}

/** How queued calls of a write method make one: `start` copies a call's argument, undefined when it joins none. */
interface Merge {
  start(argument: unknown): any;
  join(merged: any, argument: unknown): boolean;
}

type Outcome = { ok: true; value: unknown } | { ok: false; error: unknown };

const outcome = (call: () => unknown): Promise<Outcome> => Promise.resolve().then(call).then(
  (value) => ({ ok: true, value }),
  (error) => ({ ok: false, error }),
);

/** The write waiting for those in flight, which the next calls of its method join until another call comes. */
interface Batch {
  merge: Merge;
  argument: any;
  parts: unknown[];
  done: Promise<Outcome[]>;
}

const batches = new WeakMap<object, Batch>();

/** The answer to `argument`'s write, made in one call with the writes queued next to it; undefined when it joins none. */
function batched(area: object, pending: Promise<unknown>, merge: Merge, original: (argument: unknown) => unknown, argument: unknown) {
  let batch = batches.get(area);
  if (batch?.merge !== merge || !merge.join(batch.argument, argument)) {
    const merged = merge.start(argument);
    if (merged === undefined) return undefined;
    const queued: Batch = batch = { merge, argument: merged, parts: [], done: undefined! };
    queued.done = pending.then(async () => {
      if (batches.get(area) === queued) batches.delete(area);
      const all = await outcome(() => original.call(area, queued.argument));
      if (all.ok || queued.parts.length === 1) return queued.parts.map(() => all);
      // One call failing fails the merged one: each goes again on its own, for its own answer.
      const outcomes: Outcome[] = [];
      for (const part of queued.parts) outcomes.push(await outcome(() => original.call(area, part)));
      return outcomes;
    });
    batches.set(area, queued);
    inFlight(area, queued.done);
  }
  const index = batch.parts.push(argument) - 1;
  return batch.done.then((outcomes) => {
    const own = outcomes[index];
    if (own.ok) return own.value;
    throw own.error;
  });
}

/** Set from an answer settling until a later task runs: an answer settling meanwhile waits for a task of its own. */
let nextTask: MessagePort | undefined;
const waiting: Array<() => void> = [];

/** `answer`, settled in a task no other storage answer settles in, in the order the answers come. */
function ownTask(answer: unknown): unknown {
  if (typeof (answer as PromiseLike<unknown> | undefined)?.then !== 'function') return answer;
  const settle = (value: unknown, failed: boolean) => {
    const result = () => (failed ? Promise.reject(value) : value);
    if (nextTask) return new Promise<void>((resolve) => { waiting.push(resolve); }).then(result);
    // Closed once no answer waits, so nothing stays open at idle.
    const { port1, port2 } = new MessageChannel();
    port1.onmessage = () => {
      const next = waiting.shift();
      if (next) {
        next();
        port2.postMessage(null);
        return;
      }
      port1.close();
      nextTask = undefined;
    };
    nextTask = port2;
    port2.postMessage(null);
    return result();
  };
  return Promise.resolve(answer).then((value) => settle(value, false), (error) => settle(error, true));
}

function ordered(write: boolean, merge?: Merge): Patch {
  return (original, self) => function (this: unknown, ...args: any[]) {
    const area = self(this);
    const pending = writesInFlight.get(area);
    if (merge && pending !== undefined && (args.length === 1 || (args.length === 2 && typeof args[1] === 'function'))) {
      const result = batched(area, pending, merge, original, args[0]);
      if (result) return args.length === 2 ? callbackify(() => result, args[1]) : ownTask(result);
    }
    batches.delete(area);
    const starting = write ? undefined : workerStarting();
    if (!write && pending === undefined && !starting) return ownTask(original.apply(this, args));
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
    if (write) inFlight(area, result);
    if (callback) return undefined;
    return ownTask(starting ? result.then((value) => starting.then(() => value)) : result);
  };
}

const read = ordered(false);
const write = ordered(true);

// Disjoint keys only, so each key's onChanged change carries the old and new values Chrome gives.
const mergeSets: Merge = {
  start: (items) => (items !== null && typeof items === 'object' && !Array.isArray(items) ? { ...items } : undefined),
  join(merged, items) {
    if (items === null || typeof items !== 'object' || Array.isArray(items) || Object.keys(items).some((key) => Object.hasOwn(merged, key))) return false;
    Object.assign(merged, items);
    return true;
  },
};

const keyList = (keys: unknown): string[] | undefined => (typeof keys === 'string'
  ? [keys]
  : Array.isArray(keys) && keys.every((key) => typeof key === 'string') ? keys : undefined);

const mergeRemoves: Merge = {
  start: (keys) => keyList(keys)?.slice(),
  join(merged, keys) {
    const list = keyList(keys);
    if (list) merged.push(...list);
    return list !== undefined;
  },
};

/**
 * WebKit stores the enumerable keys `items` inherits too, which Chrome ignores, and rejects the call over an inherited
 * function (Night Eye adds its storage methods to Object.prototype): they are not enumerable while WebKit reads `items`.
 */
function ownKeysOnly<T>(items: any, store: () => T): T {
  const hidden: Array<[object, string, PropertyDescriptor]> = [];
  for (const key in items) {
    if (Object.hasOwn(items, key)) continue;
    for (let owner = Object.getPrototypeOf(items); owner; owner = Object.getPrototypeOf(owner)) {
      const descriptor = Object.getOwnPropertyDescriptor(owner, key);
      if (!descriptor) continue;
      if (descriptor.configurable) {
        Object.defineProperty(owner, key, { enumerable: false });
        hidden.push([owner, key, descriptor]);
      }
      break;
    }
  }
  try {
    return store();
  } finally {
    for (const [owner, key, descriptor] of hidden) Object.defineProperty(owner, key, descriptor);
  }
}

const setWithinQuota: Patch = (original, self) => function (this: unknown, items: any, callback?: () => void) {
  const area: any = self(this);
  // Called at once, so arguments WebKit rejects still throw.
  const first = ownKeysOnly(items, () => original.call(area, items));
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
        return await ownKeysOnly(items, () => original.call(area, items));
      } catch {
        await original.call(area, old);
        throw error;
      }
    }
  }, callback);
};

/**
 * `value` as Chrome stores it: its objects without their non-finite numbers and functions, which Chrome leaves out
 * where WebKit stores the numbers as null and rejects the call over a function of `items` itself; an array's become
 * null in both. Copies only what changes; a cycle is left for WebKit to reject.
 */
function asChromeStores(value: any, seen = new Set<object>()): any {
  if (typeof value !== 'object' || value === null || seen.has(value)) return value;
  seen.add(value);
  let copy: any;
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const next = typeof value[i] === 'function' ? null : asChromeStores(value[i], seen);
      if (next !== value[i]) (copy ??= [...value])[i] = next;
    }
  } else {
    for (const key of Object.keys(value)) {
      const item = value[key];
      if (typeof item === 'function' || (typeof item === 'number' && !Number.isFinite(item))) {
        copy ??= { ...value };
        delete copy[key];
        continue;
      }
      const next = asChromeStores(item, seen);
      if (next !== item) (copy ??= { ...value })[key] = next;
    }
  }
  seen.delete(value);
  return copy ?? value;
}

export const storageAreaPatches: Record<string, Patch> = {
  get: read, getBytesInUse: read, getKeys: read, remove: ordered(true, mergeRemoves), clear: write,
  set: (original, self) => {
    const set = ordered(true, mergeSets)(setWithinQuota(original, self), self);
    return function (this: unknown, items: any, ...rest: unknown[]) {
      return set.call(this, asChromeStores(items), ...rest);
    };
  },
};
