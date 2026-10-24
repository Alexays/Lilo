// The stream id native hands back is single-use, redeemed by the tab-share shim's getUserMedia
// (`chromeMediaSource: 'desktop'`). SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { chromeEnum } from '../shared/chrome-enum.ts';
import { tabPosition } from './tabGroups.ts';

const SOURCES = ['screen', 'window', 'tab', 'audio'];
const SIGNATURE = 'desktopCapture.chooseDesktopMedia(array sources, optional tabs.Tab targetTab, function callback)';

type Callback = (streamId: string, options?: { canRequestAudioTrack: boolean }) => void;

// Ids are only compared within one extension; a random start keeps its pages and worker apart.
let lastRequestId = Math.floor(Math.random() * 1e6);

export const desktopCaptureAugmentation = {
  DesktopCaptureSourceType: chromeEnum(SOURCES),

  chooseDesktopMedia(sources: string[], targetTab?: { id?: number } | Callback, callback?: Callback): number {
    const [tab, cb] = typeof targetTab === 'function' ? [undefined, targetTab] : [targetTab, callback];
    if (!Array.isArray(sources) || sources.some((source) => !SOURCES.includes(source))) {
      throw new TypeError(`Error in invocation of ${SIGNATURE}: Error at parameter 'sources': Value must be one of ${SOURCES.join(', ')}.`);
    }
    if (typeof cb !== 'function') throw new TypeError(`Error in invocation of ${SIGNATURE}: No matching signature.`);
    const requestId = ++lastRequestId;
    callbackify(async () => {
      const params: Record<string, unknown> = { requestId, sources };
      if (tab) params.target = await tabPosition(tab.id);
      return gapCall<{ streamId: string; canRequestAudioTrack?: boolean }>('desktopCapture', 'chooseDesktopMedia', params);
    }, (result) => (result ? cb(result.streamId, { canRequestAudioTrack: !!result.canRequestAudioTrack }) : cb(undefined as unknown as string)));
    return requestId;
  },

  cancelChooseDesktopMedia(desktopMediaRequestId: number): void {
    gapCall('desktopCapture', 'cancelChooseDesktopMedia', { requestId: desktopMediaRequestId }).catch(() => {});
  },
};
