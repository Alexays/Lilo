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

  describe('onDeterminingFilename', () => {
    const event = downloadsAugmentation.onDeterminingFilename as any;
    const item = { url: 'https://example.com/a.zip', filename: 'a.zip' };
    const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
    // As the port sends them, without undefined fields.
    const answers = () => gapCalls.filter((call) => call.method === 'suggestFilename').map((call) => JSON.parse(JSON.stringify(call.params)));

    async function determine(listener: (...args: any[]) => unknown): Promise<unknown[]> {
      event.addListener(listener);
      event.dispatch(item, 'lilo-filename-1');
      event.removeListener(listener);
      await settle();
      return answers();
    }

    it('sends a suggestion made in the listener', async () => {
      let heard: unknown;
      const sent = await determine((downloadItem: unknown, suggest: (suggestion: unknown) => void) => {
        heard = downloadItem;
        suggest({ filename: 'zips/a.zip', conflictAction: 'overwrite' });
      });

      assert.deepEqual(heard, item);
      assert.deepEqual(sent, [{ requestId: 'lilo-filename-1', filename: 'zips/a.zip', conflictAction: 'overwrite' }]);
    });

    it('waits for a listener that returned true to suggest later', async () => {
      let suggestLater: (suggestion: unknown) => void = () => {};
      const sent = await determine((_: unknown, suggest: (suggestion: unknown) => void) => {
        suggestLater = suggest;
        return true;
      });
      assert.deepEqual(sent, []);

      suggestLater({ filename: 'later/a.zip' });
      await settle();

      assert.deepEqual(answers(), [{ requestId: 'lilo-filename-1', filename: 'later/a.zip' }]);
    });

    it('answers with no suggestion for a listener that neither suggests nor returns true', async () => {
      const sent = await determine(() => undefined);

      assert.deepEqual(sent, [{ requestId: 'lilo-filename-1' }]);
    });

    it('reports its listener to native', () => {
      assert.ok(event instanceof GapChromeEvent);
    });
  });
});
