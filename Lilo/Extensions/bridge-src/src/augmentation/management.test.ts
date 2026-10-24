import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: unknown }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(nextResult)));
});

(globalThis as any).chrome = { runtime: { id: 'test-extension-id' } };

const { managementAugmentation } = await import('./management.ts');

describe('managementAugmentation', () => {
  it('getSelf leaves the caller identity to native', async () => {
    gapCalls.length = 0;
    nextResult = { id: 'test-extension-id' };

    await managementAugmentation.getSelf();

    assert.deepEqual(gapCalls[0], {
      namespace: 'management',
      method: 'getSelf',
      params: {},
    });
  });

  it('getPermissionWarningsByManifest sends manifestStr to Swift', async () => {
    gapCalls.length = 0;
    nextResult = ['This extension requests the "tabs" permission'];

    await managementAugmentation.getPermissionWarningsByManifest('{"permissions":["tabs"]}');

    assert.deepEqual(gapCalls[0], {
      namespace: 'management',
      method: 'getPermissionWarningsByManifest',
      params: { manifestStr: '{"permissions":["tabs"]}' },
    });
  });

  it('uninstall takes a callback in place of options', async () => {
    gapCalls.length = 0;
    nextResult = undefined;
    await new Promise<void>((resolve) => managementAugmentation.uninstall('other-id', resolve));

    assert.deepEqual(gapCalls[0], {
      namespace: 'management',
      method: 'uninstall',
      params: { id: 'other-id', showConfirmDialog: false },
    });
  });

  it('uninstallSelf forwards showConfirmDialog', async () => {
    gapCalls.length = 0;
    nextResult = undefined;

    await managementAugmentation.uninstallSelf({ showConfirmDialog: true });

    assert.deepEqual(gapCalls[0], {
      namespace: 'management',
      method: 'uninstallSelf',
      params: { showConfirmDialog: true },
    });
  });
});

describe('managementAugmentation app calls', () => {
  it('tells native whether a user gesture is active', async () => {
    gapCalls.length = 0;
    nextResult = null;
    const nodeNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
    Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { userActivation: { isActive: true } } });
    try {
      await managementAugmentation.createAppShortcut('app');
    } finally {
      if (nodeNavigator) Object.defineProperty(globalThis, 'navigator', nodeNavigator);
    }
    await managementAugmentation.setLaunchType('app', 'OPEN_AS_WINDOW');

    assert.deepEqual(gapCalls.map((call) => call.params), [
      { id: 'app', userGesture: true },
      { id: 'app', launchType: 'OPEN_AS_WINDOW', userGesture: false },
    ]);
  });
});
