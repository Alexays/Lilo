import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return Promise.resolve({ partitionKey: { topLevelSite: 'https://example.com', hasCrossSiteAncestor: false } });
});
(globalThis as any).chrome = {
  windows: { getAll: async () => [{ id: 1 }] },
  tabs: { get: async (id: number) => { if (id !== 4) throw new Error('Invalid tab'); return { id: 4, index: 2, windowId: 1 }; } },
};

const { permissionsAdditions } = await import('./permissions.ts');
const { getPartitionKey } = await import('./cookies.ts');

beforeEach(() => { gapCalls.length = 0; });

describe('permissions host access requests', () => {
  it('needs exactly one of documentId and tabId', async () => {
    const error = { message: "Must specify either 'documentId' or 'tabId'." };
    await assert.rejects(permissionsAdditions.addHostAccessRequest({}) as Promise<void>, error);
    await assert.rejects(permissionsAdditions.removeHostAccessRequest({ tabId: 4, documentId: 'd' }) as Promise<void>, error);
  });

  it('fails for a document or tab Lilo does not know', async () => {
    await assert.rejects(permissionsAdditions.addHostAccessRequest({ documentId: 'd1' }) as Promise<void>, { message: "No document with ID 'd1'." });
    await assert.rejects(permissionsAdditions.addHostAccessRequest({ tabId: 8 }) as Promise<void>, { message: 'No tab with id: 8.' });
    assert.equal(gapCalls.length, 0);
  });

  it('sends the tab position and pattern', async () => {
    await permissionsAdditions.addHostAccessRequest({ tabId: 4, pattern: 'https://example.com/*' });

    assert.deepEqual(gapCalls[0], {
      namespace: 'permissions',
      method: 'addHostAccessRequest',
      params: { tab: { windowPosition: 0, index: 2 }, tabId: 4, pattern: 'https://example.com/*' },
    });
  });
});

describe('cookies.getPartitionKey', () => {
  it('fails with Chrome errors for what Lilo cannot name', async () => {
    await assert.rejects(getPartitionKey({}) as Promise<unknown>, { message: 'Either `documentId` or `tabId` must be specified.' });
    await assert.rejects(getPartitionKey({ frameId: 0 }) as Promise<unknown>, { message: '`frameId` may not be 0 if no `tabId` is present.' });
    await assert.rejects(getPartitionKey({ tabId: 8 }) as Promise<unknown>, { message: 'Invalid `tabId`.' });
    await assert.rejects(getPartitionKey({ tabId: 4, frameId: 3 }) as Promise<unknown>, { message: 'Invalid `frameId`.' });
    assert.equal(gapCalls.length, 0);
  });

  it('asks native for the main frame key of the tab', async () => {
    const key = await getPartitionKey({ tabId: 4 });

    assert.deepEqual(key, { partitionKey: { topLevelSite: 'https://example.com', hasCrossSiteAncestor: false } });
    assert.deepEqual(gapCalls[0].params, { tab: { windowPosition: 0, index: 2 } });
  });
});
