import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';
import { ChromeEvent } from '../shared/chrome-event.ts';

export const notificationsAugmentation = {
  create(
    notificationId: string | object | null | undefined,
    options?: object,
    callback?: (id: string) => void
  ) {
    // Chrome API allows create(options, cb) or create(id, options, cb), where an undefined or null id is omitted.
    const [id, opts, cb] =
      typeof notificationId === 'object' && notificationId !== null
        ? ['', notificationId, options as unknown as ((id: string) => void) | undefined]
        : [notificationId ?? '', options ?? {}, callback];
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
  // no native hook, so it stays an inert local event for feature detection.
  ...createGapEventsFromNames('notifications', ['onClicked', 'onClosed', 'onButtonClicked']),
  onPermissionLevelChanged: new ChromeEvent<['granted' | 'denied']>(),
};
