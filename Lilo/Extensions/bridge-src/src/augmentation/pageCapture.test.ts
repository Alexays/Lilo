import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI(async (msg: any) => {
  gapCalls.push(msg);
  if (nextResult instanceof Error) throw nextResult;
  return nextResult;
});
// Tab 7 is the second tab of the second window.
(globalThis as any).chrome = {
  runtime: {},
  windows: { getAll: async () => [{ id: 1 }, { id: 2 }] },
  tabs: {
    get: async (id: number) => {
      if (id !== 7) throw new Error(`No tab with id: ${id}.`);
      return { id: 7, index: 1, windowId: 2 };
    },
  },
};

const { pageCaptureAugmentation } = await import('./pageCapture.ts');
const { liloLastError } = await import('../shared/callbackify.ts');

describe('pageCapture', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = 'From: <Saved by Lilo>\r\n';
  });

  it('sends the tab as its window position and index, and answers the MHTML as an untyped Blob', async () => {
    const blob = await pageCaptureAugmentation.saveAsMHTML({ tabId: 7 })!;
    assert.deepEqual(gapCalls, [{ namespace: 'pageCapture', method: 'saveAsMHTML', params: { tab: { windowPosition: 1, index: 1 } } }]);
    assert.ok(blob instanceof Blob);
    assert.equal(blob.type, '');
    assert.equal(await blob.text(), 'From: <Saved by Lilo>\r\n');
  });

  it("fails an unknown tab with Chrome's error, without asking native", async () => {
    await assert.rejects(pageCaptureAugmentation.saveAsMHTML({ tabId: 999 })!, { message: 'Cannot find the tab for this request.' });
    assert.equal(gapCalls.length, 0);
  });

  it('hands a callback the native error as lastError', async () => {
    nextResult = new Error("Don't have permissions required to capture this page.");
    const outcome = await new Promise((resolve) => {
      pageCaptureAugmentation.saveAsMHTML({ tabId: 7 }, (data) => resolve([data, liloLastError()?.message]));
    });
    assert.deepEqual(outcome, [undefined, "Don't have permissions required to capture this page."]);
  });
});
