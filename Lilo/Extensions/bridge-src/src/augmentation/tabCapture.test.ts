import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;
let userMediaConstraints: any;

mockGapAPI(async (msg: any) => {
  gapCalls.push(msg);
  if (nextResult instanceof Error) throw nextResult;
  return nextResult;
});
// Two windows: tab 7 is the second tab of window 2, tab 3 the active tab of window 1.
const tabs: Record<number, { id: number; index: number; windowId: number; active: boolean }> = {
  3: { id: 3, index: 0, windowId: 1, active: true },
  7: { id: 7, index: 1, windowId: 2, active: false },
};
(globalThis as any).chrome = {
  runtime: {},
  windows: { getAll: async () => [{ id: 1 }, { id: 2 }] },
  tabs: {
    get: async (id: number) => {
      if (!tabs[id]) throw new Error(`No tab with id: ${id}.`);
      return tabs[id];
    },
    query: async (info: any) => Object.values(tabs).filter((t) => !info.active || t.active),
  },
};
Object.defineProperty(globalThis, 'navigator', {
  value: { mediaDevices: { getUserMedia: async (c: any) => { userMediaConstraints = c; return { id: 'stream' }; } } },
  configurable: true,
});

const { tabCaptureAugmentation, captureTab } = await import('./tabCapture.ts');
const tabCapture = tabCaptureAugmentation as any;

describe('tabCapture', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = 'stream-id';
    userMediaConstraints = undefined;
  });

  it('getMediaStreamId sends the target tab as its window position and index, with its id', async () => {
    assert.equal(await tabCapture.getMediaStreamId({ targetTabId: 7 }), 'stream-id');
    assert.deepEqual(gapCalls[0], {
      namespace: 'tabCapture', method: 'getMediaStreamId', params: { tabId: 7, target: { windowPosition: 1, index: 1 } },
    });
  });

  it('getMediaStreamId defaults to the active tab and resolves a consumer tab too', async () => {
    await tabCapture.getMediaStreamId({ consumerTabId: 7 });
    assert.deepEqual(gapCalls[0].params, {
      tabId: 3, target: { windowPosition: 0, index: 0 }, consumer: { windowPosition: 1, index: 1 },
    });
  });

  it('getMediaStreamId rejects an unknown tab without calling native', async () => {
    await assert.rejects(tabCapture.getMediaStreamId({ targetTabId: 99 }), /Invalid tab specified\./);
    assert.equal(gapCalls.length, 0);
  });

  it('getMediaStreamId takes a callback as its only argument', async () => {
    const id = await new Promise((resolve) => tabCapture.getMediaStreamId(resolve));
    assert.equal(id, 'stream-id');
  });

  it('getCapturedTabs returns what native reports', async () => {
    nextResult = [{ tabId: 3, status: 'active', fullscreen: false }];
    assert.deepEqual(await tabCapture.getCapturedTabs(), [{ tabId: 3, status: 'active', fullscreen: false }]);
  });

  it('capture asks getUserMedia for the stream id with the caller constraints', async () => {
    const stream = await new Promise((resolve) => captureTab(
      { video: true, videoConstraints: { mandatory: { maxWidth: 1280 } } },
      resolve,
    ));
    assert.deepEqual(stream, { id: 'stream' });
    assert.deepEqual(userMediaConstraints, {
      audio: false,
      video: { mandatory: { maxWidth: 1280, chromeMediaSource: 'tab', chromeMediaSourceId: 'stream-id' } },
    });
  });

  it('capture without audio or video calls back with null', async () => {
    const stream = await new Promise((resolve) => captureTab({}, resolve));
    assert.equal(stream, null);
    assert.equal(gapCalls.length, 0);
  });
});
