// Augments chrome.sessions with gap-bridged recently-closed access. WebKit ships no sessions API;
// Lilo backs it with the window's recently-closed-tab stack (no cross-device sync, so getDevices
// returns an empty list).
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';

export const sessionsAugmentation = {
  MAX_SESSION_RESULTS: 25,

  getRecentlyClosed(filter?: any, callback?: (sessions: any[]) => void) {
    const [f, cb] = typeof filter === 'function' ? [{}, filter] : [filter ?? {}, callback];
    return callbackify(
      () => gapCall<any[]>('sessions', 'getRecentlyClosed', { maxResults: f?.maxResults }),
      cb
    );
  },

  getDevices(filter?: any, callback?: (devices: any[]) => void) {
    // No account sync in Lilo: report zero synced devices.
    const cb = typeof filter === 'function' ? filter : callback;
    return callbackify(async () => [] as any[], cb);
  },

  restore(sessionId?: string, callback?: (restored: any) => void) {
    const [id, cb] = typeof sessionId === 'function' ? [undefined, sessionId] : [sessionId, callback];
    return callbackify(
      () => gapCall<any>('sessions', 'restore', { sessionId: id }),
      cb
    );
  },

  // Native pushes it when a closed tab joins or leaves the stack.
  ...createGapEventsFromNames('sessions', ['onChanged']),
};
