import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: unknown }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(nextResult)));
});

(globalThis as any).chrome = { runtime: {} };

const { identityAugmentation } = await import('./identity.ts');

describe('identityAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = undefined;
  });

  it('launchWebAuthFlow routes to the Swift gap API', async () => {
    nextResult = 'https://example.com/callback#token=abc';

    const result = await identityAugmentation.launchWebAuthFlow({ url: 'https://example.com/auth', interactive: true });

    assert.equal(result, 'https://example.com/callback#token=abc');
    assert.deepEqual(gapCalls[0], {
      namespace: 'identity',
      method: 'launchWebAuthFlow',
      params: { url: 'https://example.com/auth', interactive: true },
    });
  });

  it('getAuthToken resolves Chrome\'s token result', async () => {
    nextResult = { token: 'secret-token', grantedScopes: ['email'] };

    const result = await identityAugmentation.getAuthToken({ scopes: ['email'] });

    assert.deepEqual(result, { token: 'secret-token', grantedScopes: ['email'] });
    assert.deepEqual(gapCalls[0], {
      namespace: 'identity',
      method: 'getAuthToken',
      params: { scopes: ['email'] },
    });
  });

  it('getAuthToken hands a callback the token and the granted scopes', async () => {
    nextResult = { token: 't', grantedScopes: ['a', 'b'] };

    const [token, scopes] = await new Promise<unknown[]>((resolve) =>
      identityAugmentation.getAuthToken({ interactive: true }, (...args: unknown[]) => resolve(args)));

    assert.deepEqual([token, scopes], ['t', ['a', 'b']]);
  });
});
