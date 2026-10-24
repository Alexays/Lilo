import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string }> = [];

mockGapAPI(async (msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method });
  return msg.method === 'getID' ? 'cAbCdEfGhIj' : msg.method === 'getCreationTime' ? 1700000000000 : undefined;
});
(globalThis as any).chrome = { runtime: {} };

const { instanceIDAugmentation } = await import('./instanceID.ts');
const { liloLastError } = await import('../shared/callbackify.ts');

describe('instanceID', () => {
  beforeEach(() => {
    gapCalls.length = 0;
  });

  it('asks native for the ID, its creation time and its deletion', async () => {
    assert.equal(await instanceIDAugmentation.getID(), 'cAbCdEfGhIj');
    assert.equal(await instanceIDAugmentation.getCreationTime(), 1700000000000);
    assert.equal(await instanceIDAugmentation.deleteID(), undefined);
    assert.deepEqual(gapCalls.map(({ method }) => method), ['getID', 'getCreationTime', 'deleteID']);
  });

  it('fails tokens as Chrome does with Instance ID disabled, callbacks with lastError', async () => {
    const disabled = 'Instance ID is currently disabled.';
    await assert.rejects(instanceIDAugmentation.getToken({ authorizedEntity: '1', scope: 'GCM' })!, { message: disabled });
    await assert.rejects(instanceIDAugmentation.deleteToken({ authorizedEntity: '1', scope: 'GCM' })!, { message: disabled });
    const outcome = await new Promise((resolve) => {
      instanceIDAugmentation.getToken({ authorizedEntity: '1', scope: 'GCM' }, (token) => resolve([token, liloLastError()?.message]));
    });
    assert.deepEqual(outcome, [undefined, disabled]);
    assert.equal(gapCalls.length, 0);
  });

  it('has onTokenRefresh', () => {
    assert.equal(typeof instanceIDAugmentation.onTokenRefresh.addListener, 'function');
  });
});
