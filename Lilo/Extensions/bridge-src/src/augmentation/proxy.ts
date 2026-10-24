// chrome.proxy: `settings` is a ChromeSetting native keeps per extension and applies to the profile.
//
// SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { chromeEnum } from '../shared/chrome-enum.ts';
import { GapChromeEvent } from '../shared/gap-event.ts';

export const proxyAugmentation = {
  Scheme: chromeEnum(['http', 'https', 'quic', 'socks4', 'socks5']),
  Mode: chromeEnum(['direct', 'auto_detect', 'pac_script', 'fixed_servers', 'system']),
  settings: {
    get(details: { incognito?: boolean }, callback?: (result: unknown) => void) {
      return callbackify(() => gapCall('proxy', 'get', details ?? {}), callback);
    },
    set(details: { value: unknown; scope?: string }, callback?: () => void) {
      return callbackify(async () => { await gapCall('proxy', 'set', details ?? {}); }, callback);
    },
    clear(details: { scope?: string }, callback?: () => void) {
      return callbackify(async () => { await gapCall('proxy', 'clear', details ?? {}); }, callback);
    },
    onChange: new GapChromeEvent<[unknown]>('proxy', 'settings.onChange'),
  },
  onProxyError: new GapChromeEvent<[unknown]>('proxy', 'onProxyError'),
};
