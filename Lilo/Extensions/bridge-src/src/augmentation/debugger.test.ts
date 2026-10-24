import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI, pushGapEvent } from '../shared/ipc.testkit.ts';

const calls: Array<{ method: string; params: any }> = [];
let reply: (method: string, params: any) => unknown = () => undefined;

mockGapAPI(async (msg: any) => {
  calls.push({ method: msg.method, params: msg.params });
  return reply(msg.method, msg.params);
});

const tabs = [
  { id: 11, index: 0, windowId: 1, favIconUrl: 'https://a.test/favicon.ico' },
  { id: 12, index: 1, windowId: 1 },
  { id: 21, index: 0, windowId: 2 },
];
(globalThis as any).chrome = {
  windows: {
    getAll: async (info?: { populate?: boolean }) => [1, 2].map((id) => (info?.populate ? { id, tabs: tabs.filter((t) => t.windowId === id) } : { id })),
  },
  tabs: {
    get: async (id: number) => {
      const tab = tabs.find((t) => t.id === id);
      if (!tab) throw new Error(`No tab with id: ${id}.`);
      return tab;
    },
  },
};

const { debuggerAugmentation: debug } = await import('./debugger.ts');
(globalThis as any).chrome.debugger = debug;

describe('debugger', () => {
  beforeEach(() => {
    calls.length = 0;
    reply = () => undefined;
  });

  it('attaches to a tab by its position and keeps the debuggee as named', async () => {
    await debug.attach({ tabId: 21, url: 'ignored' } as any, '1.3');
    assert.deepEqual(calls.at(-1), {
      method: 'attach',
      params: { target: { tabId: 21 }, tab: { windowPosition: 1, index: 0 }, requiredVersion: '1.3' },
    });
  });

  it('lets native report an unknown tab, after the version check', async () => {
    reply = (method, params) => {
      if (method === 'attach' && !params.tab) throw new Error('No tab with given id 99.');
    };
    await assert.rejects(() => debug.attach({ tabId: 99 }, '1.3')!, /^Error: No tab with given id 99\.$/);
  });

  it('fails without a debuggee, as Chrome does', async () => {
    await assert.rejects(async () => debug.attach({} as any, '1.3'), /Either tab id or extension id must be specified\./);
  });

  it('sends a command and resolves with its result, params optional', async () => {
    reply = (method) => (method === 'sendCommand' ? { result: { type: 'number', value: 42 } } : undefined);
    const result = await debug.sendCommand({ tabId: 11 }, 'Runtime.evaluate', { expression: '6*7', returnByValue: true });
    assert.deepEqual(result, { result: { type: 'number', value: 42 } });
    assert.deepEqual(calls.at(-1)!.params, { target: { tabId: 11 }, method: 'Runtime.evaluate', params: { expression: '6*7', returnByValue: true } });

    const viaCallback = await new Promise((resolve) => debug.sendCommand({ tabId: 11 }, 'Page.enable', resolve));
    assert.deepEqual(calls.at(-1)!.params.params, {});
    assert.ok(viaCallback);
  });

  it('names an unknown tab rather than a missing session', async () => {
    reply = (method, params) => {
      if (method === 'sendCommand' || method === 'detach') throw new Error(`Debugger is not attached to the tab with id: ${params.target.tabId}.`);
    };
    await assert.rejects(() => debug.sendCommand({ tabId: 12 }, 'Page.enable')!, /^Error: Debugger is not attached to the tab with id: 12\.$/);
    await assert.rejects(() => debug.detach({ tabId: 404 })!, /^Error: No tab with given id 404\.$/);
  });

  it('turns native positions into tab ids for getTargets', async () => {
    reply = (method) => (method === 'getTargets'
      ? [
          { tab: { windowPosition: 0, index: 0 }, id: 'A', title: 'A', url: 'https://a.test/', attached: true },
          { tab: { windowPosition: 1, index: 0 }, id: 'B', title: 'B', url: 'https://b.test/', attached: false },
          { tab: { windowPosition: 5, index: 0 }, id: 'gone', title: '', url: '', attached: false },
        ]
      : undefined);
    const targets = await debug.getTargets();
    assert.deepEqual(targets, [
      { type: 'page', id: 'A', title: 'A', url: 'https://a.test/', attached: true, tabId: 11, faviconUrl: 'https://a.test/favicon.ico' },
      { type: 'page', id: 'B', title: 'B', url: 'https://b.test/', attached: false, tabId: 21 },
    ]);
  });

  it('fires onEvent and onDetach with what native sends', () => {
    const heard: unknown[] = [];
    debug.onEvent.addListener((source, method, params) => heard.push([source, method, params]));
    debug.onDetach.addListener((source, reason) => heard.push([source, reason]));
    pushGapEvent({ namespace: 'debugger', event: 'onEvent', args: [{ tabId: 11 }, 'Network.loadingFinished', { requestId: '1' }] });
    pushGapEvent({ namespace: 'debugger', event: 'onDetach', args: [{ tabId: 11 }, debug.DetachReason.CANCELED_BY_USER] });
    assert.deepEqual(heard, [
      [{ tabId: 11 }, 'Network.loadingFinished', { requestId: '1' }],
      [{ tabId: 11 }, 'canceled_by_user'],
    ]);
  });
});
