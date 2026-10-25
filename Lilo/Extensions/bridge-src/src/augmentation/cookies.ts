// Replaces WebKit's onChanged, which lacks changeInfo (webkit.org/b/267514) and wakes the worker on every cookie
// change; storeId comes from WebKit's store list to match cookies.get. SW-safe: no window/document/webkit.
import { gapListenerReported, resolvingEvent } from '../shared/gap-event.ts';
import type { Patch } from '../shared/chrome-compat.ts';
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { tabPositions } from './tabGroups.ts';

interface CookieChangeInfo {
  cookie: Record<string, unknown>;
  removed: boolean;
  cause: string;
}

let storeId: Promise<string | undefined> | undefined;

export const cookiesOnChanged = resolvingEvent<CookieChangeInfo>('cookies', 'onChanged', async (info) => {
  if (!info.cookie) return null;
  storeId ??= Promise.resolve()
    .then(() => bridgeChrome().cookies.getAllCookieStores())
    .then((stores: { id?: string }[] | undefined) => stores?.[0]?.id)
    .catch(() => undefined);
  const id = await storeId;
  return [id === undefined ? info : { ...info, cookie: { ...info.cookie, storeId: id } }];
});

/**
 * Once the context listens to onChanged, a change it makes waits for Lilo to have read the cookies,
 * and settles once Lilo reported it: Lilo reports each of the changes made one after another, as Chrome.
 */
const afterListening: Patch = (original, self) => function (this: unknown, ...args: any[]) {
  const reported = gapListenerReported('cookies.onChanged');
  if (!reported) return original.apply(self(this), args);
  const namespace = self(this);
  const callback = typeof args.at(-1) === 'function' ? args.pop() : undefined;
  return callbackify(async () => {
    await reported;
    const result = await original.apply(namespace, args);
    await gapCall('cookies', 'changesReported').catch(() => {});
    return result;
  }, callback);
};

/**
 * WebKit checks the host access of a cookie not `secure` over http (WEBKIT-GAPS.md, gap 82): one an extension with
 * https access only sets for an https URL fails, where Chrome sets it. Lilo sets it `secure` then, as only https reaches it.
 */
const setOverHTTPS: Patch = (original, self) => function (this: unknown, details: any, ...rest: unknown[]) {
  const namespace = self(this);
  if (details?.secure !== undefined || typeof details?.url !== 'string' || !/^https:/i.test(details.url)) {
    return original.call(namespace, details, ...rest);
  }
  const callback = typeof rest[0] === 'function' ? rest[0] as (cookie?: unknown) => void : undefined;
  return callbackify(() => original.call(namespace, details).catch((error: Error) => {
    if (!/Host permissions are missing/.test(error?.message ?? '')) throw error;
    return original.call(namespace, { ...details, secure: true });
  }), callback);
};

export const cookiesPatches: Record<string, Patch> = {
  set: (original, self) => afterListening(setOverHTTPS(original, self), self),
  remove: afterListening,
};

/**
 * cookies.getPartitionKey for a tab's main frame, as Chrome checks it. Lilo knows neither WebKit's
 * frame ids nor document ids, so another frame or a document fails.
 */
export function getPartitionKey(details: { tabId?: number; frameId?: number; documentId?: string }, callback?: (details: unknown) => void) {
  return callbackify(async () => {
    const { tabId, frameId, documentId } = details ?? {};
    if (documentId !== undefined) throw new Error('Invalid `documentId`.');
    if (tabId === undefined) {
      if (frameId === undefined) throw new Error('Either `documentId` or `tabId` must be specified.');
      throw new Error(frameId === 0 ? '`frameId` may not be 0 if no `tabId` is present.' : 'Invalid `frameId`.');
    }
    const [tab] = await tabPositions([tabId]);
    if (!tab || tab.windowPosition < 0) throw new Error('Invalid `tabId`.');
    if ((frameId ?? 0) !== 0) throw new Error('Invalid `frameId`.');
    return gapCall('cookies', 'getPartitionKey', { tab });
  }, callback);
}
