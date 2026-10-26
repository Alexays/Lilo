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

const { downloadsAugmentation } = await import('./downloads.ts');
const { GapChromeEvent } = await import('../shared/gap-event.ts');
const { ChromeEvent } = await import('../shared/chrome-event.ts');

describe('downloadsAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = undefined;
  });

  it('download resolves with the Chrome download id', async () => {
    nextResult = 42;

    const result = await downloadsAugmentation.download({ url: 'https://example.com/a.zip' });

    assert.equal(result, 42);
    assert.equal(gapCalls[0].namespace, 'downloads');
    assert.equal(gapCalls[0].method, 'download');
  });

  it('pause sends the Chrome downloadId parameter', async () => {
    await downloadsAugmentation.pause(7);

    assert.deepEqual(gapCalls[0].params, { downloadId: 7 });
  });

  it('search resolves with the Chrome item array', async () => {
    nextResult = [{ id: 3, state: 'complete' }];

    const result = await downloadsAugmentation.search({ state: 'complete' });

    assert.deepEqual(result, [{ id: 3, state: 'complete' }]);
  });

  it('erase resolves with erased Chrome download ids', async () => {
    nextResult = [3, 4];

    const result = await downloadsAugmentation.erase({ state: 'complete' });

    assert.deepEqual(result, [3, 4]);
  });

  it('onDeterminingFilename is a local event that reports no listener to native', () => {
    assert.ok(downloadsAugmentation.onDeterminingFilename instanceof ChromeEvent);
    assert.ok(!(downloadsAugmentation.onDeterminingFilename instanceof GapChromeEvent));
  });
});
