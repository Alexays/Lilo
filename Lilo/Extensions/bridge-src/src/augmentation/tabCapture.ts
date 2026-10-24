// WebKit owns the integer tab ids, so each tab goes to native as its window position and index. SW-safe except
// `capture`, which only the page bundle installs (Chrome keeps it off workers).
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { GapChromeEvent, gapMethod } from '../shared/gap-event.ts';
import { tabPosition } from './tabGroups.ts';

interface GetMediaStreamOptions {
  consumerTabId?: number;
  targetTabId?: number;
}

async function activeTabId(): Promise<number> {
  const [tab] = await bridgeChrome().tabs.query({ active: true, lastFocusedWindow: true });
  if (typeof tab?.id !== 'number') throw new Error('Invalid tab specified.');
  return tab.id;
}

function getMediaStreamId(options?: GetMediaStreamOptions | ((id: string) => void), callback?: (id: string) => void) {
  const [opts, cb] = typeof options === 'function' ? [undefined, options] : [options, callback];
  return callbackify(async () => {
    const tabId = opts?.targetTabId ?? await activeTabId();
    const params: Record<string, unknown> = { tabId, target: await tabPosition(tabId) };
    if (opts?.consumerTabId !== undefined) params.consumer = await tabPosition(opts.consumerTabId);
    return gapCall<string>('tabCapture', 'getMediaStreamId', params);
  }, cb);
}

export const tabCaptureAugmentation: Record<string, unknown> = {
  onStatusChanged: new GapChromeEvent('tabCapture', 'onStatusChanged'),
  getMediaStreamId,
  getCapturedTabs: gapMethod('tabCapture', 'getCapturedTabs'),
};

interface MediaStreamConstraint {
  mandatory?: Record<string, unknown>;
  optional?: Record<string, unknown>;
}

interface CaptureOptions {
  audio?: boolean;
  video?: boolean;
  audioConstraints?: MediaStreamConstraint;
  videoConstraints?: MediaStreamConstraint;
}

/** tabCapture.capture: the active tab of the last focused window, as a stream for this page. */
export function captureTab(options: CaptureOptions, callback: (stream: unknown) => void): void {
  callbackify(async () => {
    if (!options?.audio && !options?.video) throw new Error('Capture failed. No audio or video requested.');
    const streamId = await getMediaStreamId({});
    const constraint = (wanted: boolean | undefined, extra?: MediaStreamConstraint) => wanted
      ? { ...extra, mandatory: { ...extra?.mandatory, chromeMediaSource: 'tab', chromeMediaSourceId: streamId } }
      : false;
    return (globalThis as any).navigator.mediaDevices.getUserMedia({
      audio: constraint(options.audio, options.audioConstraints),
      video: constraint(options.video, options.videoConstraints),
    });
  }, (stream) => callback?.(stream ?? null));
}
