import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(nextResult)));
});

(globalThis as any).chrome = { runtime: {} };

const { browsingDataAugmentation: browsingData } = await import('./browsingData.ts');

describe('browsingDataAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = null;
  });

  it('a remove* call clears its one data type', async () => {
    const result = await browsingData.removeLocalStorage({ since: 5 });

    assert.equal(result, undefined);
    assert.deepEqual(gapCalls[0], { namespace: 'browsingData', method: 'remove', params: { options: { since: 5 }, dataToRemove: { localStorage: true } } });
  });

  it('removePasswords fails as Chrome\'s retired type', async () => {
    await assert.rejects(browsingData.removePasswords({})!, { message: 'Requested data type is deprecated.' });
    assert.equal(gapCalls.length, 0);
  });

  it('settings lists every data type Chrome reports', async () => {
    const result: any = await browsingData.settings();

    assert.deepEqual(Object.keys(result.dataToRemove).sort(), Object.keys(result.dataRemovalPermitted).sort());
    assert.equal(Object.keys(result.dataToRemove).length, 12);
    assert.equal(result.dataToRemove.history, true);
    assert.equal(result.dataToRemove.passwords, false);
  });
});
