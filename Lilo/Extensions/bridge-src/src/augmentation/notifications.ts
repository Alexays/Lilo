import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';

export const notificationsAugmentation = {
  create(
    notificationId: string | object,
    options?: object,
    callback?: (id: string) => void
  ) {
    // Chrome API allows create(options, cb) or create(id, options, cb)
    const [id, opts, cb] =
      typeof notificationId === 'string'
        ? [notificationId, options ?? {}, callback]
        : ['', notificationId, options as unknown as ((id: string) => void) | undefined];
    return callbackify(
      // No timeout: the first create waits on the system permission prompt.
      () => gapCall<{ notificationId: string }>('notifications', 'create', { notificationId: id, ...opts }, 0)
        .then(r => r?.notificationId ?? id),
      cb
    );
  },

  clear(notificationId: string, callback?: (wasCleared: boolean) => void) {
    return callbackify(
      () => gapCall<{ wasCleared: boolean }>('notifications', 'clear', { notificationId })
        .then(r => r?.wasCleared ?? true),
      callback
    );
  },

  getAll(callback?: (notifications: Record<string, object>) => void) {
    return callbackify(
      () => gapCall<Record<string, object>>('notifications', 'getAll', {}),
      callback
    );
  },

  update(
    notificationId: string,
    options: object,
    callback?: (wasUpdated: boolean) => void
  ) {
    return callbackify(
      () => gapCall<{ wasUpdated: boolean }>('notifications', 'update', { notificationId, ...options })
        .then(r => r?.wasUpdated ?? true),
      callback
    );
  },

  getPermissionLevel(callback?: (level: 'granted' | 'denied') => void) {
    return callbackify(
      () => gapCall<{ level: 'granted' | 'denied' }>('notifications', 'getPermissionLevel', {})
        .then(r => r?.level ?? 'denied'),
      callback
    );
  },

  // onClicked/onClosed/onButtonClicked fire from native (AppDelegate). onPermissionLevelChanged has
  // no native hook, so it stays an inert listener for feature detection.
  ...createGapEventsFromNames('notifications', ['onClicked', 'onClosed', 'onButtonClicked', 'onPermissionLevelChanged']),
};
