import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

// Set up window mock before any imports that trigger IPC
const gapCalls: Array<{ namespace: string; method: string; params: unknown }> = [];

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(undefined)));
});

(globalThis as any).chrome = { runtime: {} };

const { notificationsAugmentation } = await import('./notifications.ts');

describe('notificationsAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
  });

  it('has create method', () => {
    assert.equal(typeof notificationsAugmentation.create, 'function');
  });

  it('has clear method', () => {
    assert.equal(typeof notificationsAugmentation.clear, 'function');
  });

  it('has getAll method', () => {
    assert.equal(typeof notificationsAugmentation.getAll, 'function');
  });

  it('has update method', () => {
    assert.equal(typeof notificationsAugmentation.update, 'function');
  });

  it('has onClicked event', () => {
    assert.ok(notificationsAugmentation.onClicked);
    assert.equal(typeof notificationsAugmentation.onClicked.addListener, 'function');
  });

  it('has onClosed event', () => {
    assert.ok(notificationsAugmentation.onClosed);
  });

  it('create calls gapCall with correct namespace', async () => {
    await notificationsAugmentation.create('n1', { type: 'basic', title: 'T', message: 'M', iconUrl: '' });
    assert.equal(gapCalls.length, 1);
    assert.equal(gapCalls[0].namespace, 'notifications');
    assert.equal(gapCalls[0].method, 'create');
    assert.equal((gapCalls[0].params as any).notificationId, 'n1');
  });

  it('create treats an undefined or null id as omitted, keeping the options and callback', async () => {
    for (const id of [undefined, null]) {
      gapCalls.length = 0;
      const created = await new Promise((resolve) => notificationsAugmentation.create(id, { type: 'basic', title: 'T' }, resolve));
      assert.equal(created, '');
      assert.deepEqual(gapCalls[0].params, { notificationId: '', type: 'basic', title: 'T' });
    }
  });

  it('onPermissionLevelChanged listens without telling native', async () => {
    notificationsAugmentation.onPermissionLevelChanged.addListener(() => {});
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(gapCalls.length, 0);
  });

  it('clear calls gapCall with correct notificationId param', async () => {
    await notificationsAugmentation.clear('n2');
    assert.equal(gapCalls[0].namespace, 'notifications');
    assert.equal(gapCalls[0].method, 'clear');
    assert.equal((gapCalls[0].params as any).notificationId, 'n2');
  });

  it('getAll calls gapCall with empty params', async () => {
    await notificationsAugmentation.getAll();
    assert.equal(gapCalls[0].namespace, 'notifications');
    assert.equal(gapCalls[0].method, 'getAll');
    assert.deepEqual(gapCalls[0].params, {});
  });
});
