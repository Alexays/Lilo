// The tab or window opens through WebKit's own chrome.tabs/chrome.windows, so it follows the normal open path.
// SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';

interface QueryInfo {
  text: string;
  disposition?: 'CURRENT_TAB' | 'NEW_TAB' | 'NEW_WINDOW';
  tabId?: number;
}

export const searchAugmentation = {
  Disposition: { CURRENT_TAB: 'CURRENT_TAB', NEW_TAB: 'NEW_TAB', NEW_WINDOW: 'NEW_WINDOW' },

  query(queryInfo: QueryInfo, callback?: () => void) {
    return callbackify(async () => {
      if (typeof queryInfo?.text !== 'string') throw new Error('search.query requires text');
      if (queryInfo.tabId !== undefined && queryInfo.disposition !== undefined) {
        throw new Error('Cannot set both tabId and disposition');
      }
      const url = await gapCall<string>('search', 'url', { text: queryInfo.text });
      const c = bridgeChrome();
      if (queryInfo.disposition === 'NEW_TAB') await c.tabs.create({ url });
      else if (queryInfo.disposition === 'NEW_WINDOW') await c.windows.create({ url });
      else if (queryInfo.tabId !== undefined) await c.tabs.update(queryInfo.tabId, { url });
      else await c.tabs.update({ url });
    }, callback);
  },
};
