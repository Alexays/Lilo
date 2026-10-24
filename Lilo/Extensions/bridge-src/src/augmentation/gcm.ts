// chrome.gcm as Chrome with GCM disabled: Lilo has no push backend, so every call fails with GCM_DISABLED.
// SW-safe: no window/document/webkit.
import { callbackify } from '../shared/callbackify.ts';
import { createChromeEventsFromNames } from '../shared/chrome-event.ts';

const disabled = () => Promise.reject(new Error('GCM is currently disabled.'));

export const gcmAugmentation = {
  // Chrome passes the callback an empty registration id, or the message id, beside lastError.
  register(_senderIds: string[], callback?: (registrationId: string) => void) {
    return callbackify<string>(disabled, callback && (() => callback('')));
  },
  unregister(callback?: () => void) {
    return callbackify<void>(disabled, callback);
  },
  send(message: { messageId: string }, callback?: (messageId: string) => void) {
    return callbackify<string>(disabled, callback && (() => callback(message?.messageId)));
  },
  ...createChromeEventsFromNames(['onMessage', 'onMessagesDeleted', 'onSendError']),
};
