import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI(async (msg: any) => {
  gapCalls.push(msg);
  return nextResult;
});
(globalThis as any).chrome = {
  runtime: {},
  windows: { getAll: async () => [{ id: 1 }] },
  tabs: { get: async (id: number) => ({ id, index: 2, windowId: 1 }) },
};

const { desktopCaptureAugmentation: desktopCapture } = await import('./desktopCapture.ts');

describe('desktopCapture', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = { streamId: 'desktop-id', canRequestAudioTrack: false };
  });

  it('exposes DesktopCaptureSourceType as Chrome does', () => {
    assert.deepEqual(desktopCapture.DesktopCaptureSourceType, { SCREEN: 'screen', WINDOW: 'window', TAB: 'tab', AUDIO: 'audio' });
  });

  it('chooseDesktopMedia returns a request id at once and calls back with the stream id and options', async () => {
    let id = 0;
    const result = await new Promise<unknown[]>((resolve) => {
      id = desktopCapture.chooseDesktopMedia(['screen', 'window'], (...args: unknown[]) => resolve(args));
    });
    assert.equal(typeof id, 'number');
    assert.deepEqual(result, ['desktop-id', { canRequestAudioTrack: false }]);
    assert.deepEqual(gapCalls[0].params, { requestId: id, sources: ['screen', 'window'] });
  });

  it('chooseDesktopMedia sends a target tab as its position', async () => {
    await new Promise((resolve) => desktopCapture.chooseDesktopMedia(['tab'], { id: 5 }, resolve));
    assert.deepEqual(gapCalls[0].params.target, { windowPosition: 0, index: 2 });
  });

  it('a cancelled pick calls back with an empty stream id', async () => {
    nextResult = { streamId: '' };
    const streamId = await new Promise((resolve) => desktopCapture.chooseDesktopMedia(['screen'], resolve));
    assert.equal(streamId, '');
  });

  it('each request gets its own id, which cancelChooseDesktopMedia names', () => {
    const first = desktopCapture.chooseDesktopMedia(['screen'], () => {});
    const second = desktopCapture.chooseDesktopMedia(['screen'], () => {});
    assert.notEqual(first, second);
    desktopCapture.cancelChooseDesktopMedia(first);
    assert.deepEqual(gapCalls.at(-1), { namespace: 'desktopCapture', method: 'cancelChooseDesktopMedia', params: { requestId: first } });
  });

  it('rejects unknown sources and a missing callback as Chrome does', () => {
    assert.throws(() => desktopCapture.chooseDesktopMedia(['camera'], () => {}), TypeError);
    assert.throws(() => (desktopCapture as any).chooseDesktopMedia(['screen']), TypeError);
  });
});
