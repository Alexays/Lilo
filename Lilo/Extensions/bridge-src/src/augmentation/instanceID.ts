// chrome.instanceID: Chrome makes the ID locally, and Lilo keeps it natively; Lilo has no push backend, so tokens
// fail as in Chrome with Instance ID disabled and onTokenRefresh never fires. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { ChromeEvent } from '../shared/chrome-event.ts';

const disabled = () => Promise.reject(new Error('Instance ID is currently disabled.'));

export const instanceIDAugmentation = {
  getID(callback?: (instanceID: string) => void) {
    return callbackify(() => gapCall<string>('instanceID', 'getID', {}), callback);
  },
  getCreationTime(callback?: (creationTime: number) => void) {
    return callbackify(() => gapCall<number>('instanceID', 'getCreationTime', {}), callback);
  },
  deleteID(callback?: () => void) {
    return callbackify(() => gapCall<void>('instanceID', 'deleteID', {}), callback);
  },
  getToken(_getTokenParams: unknown, callback?: (token: string) => void) {
    return callbackify<string>(disabled, callback);
  },
  deleteToken(_deleteTokenParams: unknown, callback?: () => void) {
    return callbackify<void>(disabled, callback);
  },
  onTokenRefresh: new ChromeEvent<[]>(),
};
