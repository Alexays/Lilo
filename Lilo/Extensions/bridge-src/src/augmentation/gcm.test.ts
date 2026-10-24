import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

(globalThis as any).chrome = { runtime: {} };
const { gcmAugmentation } = await import('./gcm.ts');
const { liloLastError } = await import('../shared/callbackify.ts');

const callbackResult = (call: (callback: (...args: unknown[]) => void) => void) => new Promise<unknown>((resolve) => {
  call((...args) => resolve({ args, lastError: liloLastError()?.message }));
});

describe('gcm', () => {
  it('rejects each call as Chrome does with GCM disabled', async () => {
    for (const call of [() => gcmAugmentation.register(['1']), () => gcmAugmentation.unregister(), () => gcmAugmentation.send({ messageId: 'm' })]) {
      await assert.rejects(call()!, { message: 'GCM is currently disabled.' });
    }
  });

  it("hands callbacks Chrome's arguments beside lastError", async () => {
    const disabled = 'GCM is currently disabled.';
    assert.deepEqual(await callbackResult((done) => gcmAugmentation.register(['1'], done)), { args: [''], lastError: disabled });
    assert.deepEqual(await callbackResult((done) => gcmAugmentation.send({ messageId: 'm' }, done)), { args: ['m'], lastError: disabled });
    assert.deepEqual(await callbackResult((done) => gcmAugmentation.unregister(done)), { args: [undefined], lastError: disabled });
  });

  it('has the events Chrome has', () => {
    for (const name of ['onMessage', 'onMessagesDeleted', 'onSendError']) {
      assert.equal(typeof (gcmAugmentation as any)[name].addListener, 'function');
    }
  });
});
