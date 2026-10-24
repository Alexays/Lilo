// chrome.contentSettings: one ContentSetting per type, its rules kept per extension by native.
//
// SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { chromeEnum } from '../shared/chrome-enum.ts';

const settings: Record<string, string[]> = {
  autoVerify: ['allow', 'block'],
  automaticDownloads: ['allow', 'block', 'ask'],
  camera: ['allow', 'block', 'ask'],
  clipboard: ['allow', 'block', 'ask'],
  cookies: ['allow', 'block', 'session_only'],
  images: ['allow', 'block'],
  javascript: ['allow', 'block'],
  location: ['allow', 'block', 'ask'],
  microphone: ['allow', 'block', 'ask'],
  notifications: ['allow', 'block', 'ask'],
  popups: ['allow', 'block'],
};

function contentSetting(type: string, values: string[]) {
  const request = (method: string, details: unknown) => gapCall<any>('contentSettings', method, { ...(details as object), type });
  return {
    get(details: unknown, callback?: (result: { setting: string }) => void) {
      return callbackify(() => request('get', details), callback);
    },
    set(details: { setting?: unknown }, callback?: () => void) {
      // Chrome checks the value against this type's own enum before sending, and throws.
      if (!values.includes(details?.setting as string)) {
        throw new TypeError(`Invalid invocation: Error at property 'setting': Value must be one of ${[...values].sort().join(', ')}.`);
      }
      return callbackify(async () => { await request('set', details); }, callback);
    },
    clear(details: unknown, callback?: () => void) {
      return callbackify(async () => { await request('clear', details); }, callback);
    },
    // Only plugins ever had resource identifiers.
    getResourceIdentifiers(callback?: (identifiers?: unknown[]) => void) {
      return callbackify(async () => undefined, callback);
    },
  };
}

/**
 * Chrome answers these retired types in the page itself: a warning, the callback run at once (with
 * the forced value for `get`), and no promise.
 */
function deprecatedSetting(prefName: string, value: string) {
  const answer = (method: string) => (...args: unknown[]) => {
    console.warn(`contentSettings.${prefName} is deprecated.`);
    const callback = [...args].reverse().find((arg) => typeof arg === 'function') as ((result?: unknown) => void) | undefined;
    if (callback) method === 'get' ? callback({ setting: value }) : callback();
  };
  return { get: answer('get'), set: answer('set'), clear: answer('clear'), getResourceIdentifiers: answer('getResourceIdentifiers') };
}

export const contentSettingsAugmentation = {
  Scope: chromeEnum(['regular', 'incognito_session_only']),
  AutoVerifyContentSetting: chromeEnum(['allow', 'block']),
  CameraContentSetting: chromeEnum(['allow', 'block', 'ask']),
  ClipboardContentSetting: chromeEnum(['allow', 'block', 'ask']),
  CookiesContentSetting: chromeEnum(['allow', 'block', 'session_only']),
  FullscreenContentSetting: chromeEnum(['allow']),
  ImagesContentSetting: chromeEnum(['allow', 'block']),
  JavascriptContentSetting: chromeEnum(['allow', 'block']),
  LocationContentSetting: chromeEnum(['allow', 'block', 'ask']),
  MicrophoneContentSetting: chromeEnum(['allow', 'block', 'ask']),
  MouselockContentSetting: chromeEnum(['allow']),
  MultipleAutomaticDownloadsContentSetting: chromeEnum(['allow', 'block', 'ask']),
  NotificationsContentSetting: chromeEnum(['allow', 'block', 'ask']),
  PluginsContentSetting: chromeEnum(['block']),
  PopupsContentSetting: chromeEnum(['allow', 'block']),
  PpapiBrokerContentSetting: chromeEnum(['block']),
  SoundContentSetting: chromeEnum(['allow', 'block']),
  ...Object.fromEntries(Object.entries(settings).map(([type, values]) => [type, contentSetting(type, values)])),
  fullscreen: deprecatedSetting('fullscreen', 'allow'),
  mouselock: deprecatedSetting('mouselock', 'allow'),
  plugins: deprecatedSetting('plugins', 'block'),
  unsandboxedPlugins: deprecatedSetting('ppapi-broker', 'block'),
};
