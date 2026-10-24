import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI, pushGapEvent } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(nextResult)));
});

(globalThis as any).chrome = { runtime: {} };

const { proxyAugmentation: proxy } = await import('./proxy.ts');

describe('proxyAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = null;
  });

  it('settings.get resolves with native\'s ChromeSetting details', async () => {
    nextResult = { value: { mode: 'system' }, levelOfControl: 'controllable_by_this_extension' };

    const result = await proxy.settings.get({});

    assert.deepEqual(result, { value: { mode: 'system' }, levelOfControl: 'controllable_by_this_extension' });
    assert.deepEqual(gapCalls[0], { namespace: 'proxy', method: 'get', params: {} });
  });

  it('settings.set resolves with undefined', async () => {
    assert.equal(await proxy.settings.set({ value: { mode: 'direct' } }), undefined);
    assert.deepEqual(gapCalls[0].params, { value: { mode: 'direct' } });
  });

  it('native\'s settings.onChange reaches the member event', () => {
    (globalThis as any).chrome.proxy = proxy;
    const received: unknown[] = [];
    proxy.settings.onChange.addListener((details) => received.push(details));

    pushGapEvent({ namespace: 'proxy', event: 'settings.onChange', args: [{ value: { mode: 'direct' } }] });

    assert.deepEqual(received, [{ value: { mode: 'direct' } }]);
  });
});
