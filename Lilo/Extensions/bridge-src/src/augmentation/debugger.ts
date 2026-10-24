// WebKit owns the tab ids: attach sends native the tab's position, and native's events carry back the debuggee the
// extension attached with. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { GapChromeEvent } from '../shared/gap-event.ts';
import { tabPositions } from './tabGroups.ts';

interface Debuggee {
  tabId?: number;
  extensionId?: string;
  targetId?: string;
}

interface NativeTarget {
  tab: { windowPosition: number; index: number };
  id: string;
  title: string;
  url: string;
  attached: boolean;
}

/** The debuggee's own keys, failing as Chrome does without any of them. */
function debuggee(target: Debuggee): Debuggee {
  const { tabId, extensionId, targetId } = target ?? {};
  if (typeof tabId === 'number') return { tabId };
  if (typeof extensionId === 'string') return { extensionId };
  if (typeof targetId === 'string') return { targetId };
  throw new Error('Either tab id or extension id must be specified.');
}

async function tabExists(tabId: number): Promise<boolean> {
  try {
    return typeof (await bridgeChrome().tabs.get(tabId))?.id === 'number';
  } catch {
    return false;
  }
}

/** A call on an attached debuggee: one that names an unknown tab fails as Chrome's does. */
async function onSession<T>(method: string, target: Debuggee, params: object, timeoutMs?: number): Promise<T> {
  try {
    return await gapCall<T>('debugger', method, { target, ...params }, timeoutMs);
  } catch (err) {
    if (typeof target.tabId === 'number' && /^Debugger is not attached/.test((err as Error)?.message ?? '') && !(await tabExists(target.tabId))) {
      throw new Error(`No tab with given id ${target.tabId}.`);
    }
    throw err;
  }
}

function attach(target: Debuggee, requiredVersion: string, callback?: () => void) {
  return callbackify(async () => {
    const named = debuggee(target);
    // Native checks the version first, then fails on a tab it was not given.
    const [tab] = typeof named.tabId === 'number' ? await tabPositions([named.tabId]) : [];
    await gapCall<void>('debugger', 'attach', { target: named, tab, requiredVersion });
  }, callback);
}

function detach(target: Debuggee, callback?: () => void) {
  return callbackify(async () => {
    await onSession<void>('detach', debuggee(target), {});
  }, callback);
}

type CommandCallback = (result?: object) => void;

function sendCommand(target: Debuggee, method: string, commandParams?: object | CommandCallback, callback?: CommandCallback) {
  const [params, cb] = typeof commandParams === 'function' ? [undefined, commandParams as CommandCallback] : [commandParams, callback];
  // A command can wait on the page as long as it takes, as in Chrome.
  return callbackify(() => onSession<object>('sendCommand', debuggee(target), { method: String(method), params: params ?? {} }, 0), cb);
}

function getTargets(callback?: (result: object[]) => void) {
  return callbackify(async () => {
    const [targets, windows] = await Promise.all([
      gapCall<NativeTarget[]>('debugger', 'getTargets'),
      bridgeChrome().windows.getAll({ populate: true }) as Promise<any[]>,
    ]);
    return targets.flatMap(({ tab, ...target }) => {
      const found = windows?.[tab.windowPosition]?.tabs?.find((t: any) => t.index === tab.index);
      if (typeof found?.id !== 'number') return [];
      const info: Record<string, unknown> = { type: 'page', ...target, tabId: found.id };
      if (found.favIconUrl) info.faviconUrl = found.favIconUrl;
      return [info];
    });
  }, callback);
}

export const debuggerAugmentation = {
  attach,
  detach,
  sendCommand,
  getTargets,
  onEvent: new GapChromeEvent<[Debuggee, string, object]>('debugger', 'onEvent'),
  onDetach: new GapChromeEvent<[Debuggee, string]>('debugger', 'onDetach'),
  DetachReason: { CANCELED_BY_USER: 'canceled_by_user', TARGET_CLOSED: 'target_closed' },
  TargetInfoType: { BACKGROUND_PAGE: 'background_page', OTHER: 'other', PAGE: 'page', WORKER: 'worker' },
};
