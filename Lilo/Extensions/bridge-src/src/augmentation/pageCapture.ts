// chrome.pageCapture: native writes the tab's WebKit web archive as MHTML, an ASCII document. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { tabPositions } from './tabGroups.ts';

export const pageCaptureAugmentation = {
  saveAsMHTML(details: { tabId: number }, callback?: (mhtmlData?: Blob) => void) {
    return callbackify(async () => {
      const [tab] = await tabPositions([details?.tabId]);
      if (!tab || tab.windowPosition < 0) throw new Error('Cannot find the tab for this request.');
      // Chrome's Blob has no type.
      return new Blob([await gapCall<string>('pageCapture', 'saveAsMHTML', { tab })]);
    }, callback);
  },
};
