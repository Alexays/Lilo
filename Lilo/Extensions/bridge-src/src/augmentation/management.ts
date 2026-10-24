import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames, gapMethod } from '../shared/gap-event.ts';

function hasUserGesture(): boolean {
  return (globalThis as any).navigator?.userActivation?.isActive === true;
}

export const managementAugmentation = {
  getAll: gapMethod('management', 'getAll'),
  get: gapMethod('management', 'get', ['id']),
  getSelf: gapMethod('management', 'getSelf'),
  setEnabled: gapMethod('management', 'setEnabled', ['id', 'enabled']),
  uninstall(id: string, options?: { showConfirmDialog?: boolean } | (() => void), callback?: () => void) {
    if (typeof options === 'function') [options, callback] = [undefined, options];
    const showConfirmDialog = options?.showConfirmDialog === true;
    // Removing another extension always waits on the user's answer: no timeout.
    return callbackify(() => gapCall<void>('management', 'uninstall', { id, showConfirmDialog }, 0), callback);
  },
  uninstallSelf(options?: { showConfirmDialog?: boolean } | (() => void), callback?: () => void) {
    if (typeof options === 'function') [options, callback] = [undefined, options];
    const showConfirmDialog = options?.showConfirmDialog === true;
    return callbackify(() => gapCall<void>('management', 'uninstallSelf', { showConfirmDialog }, showConfirmDialog ? 0 : undefined), callback);
  },
  getPermissionWarningsById(id: string, callback?: (warnings: string[]) => void) {
    return callbackify(
      () => gapCall<{ warnings?: string[] }>('management', 'getPermissionWarningsById', { id }).then((r) => r?.warnings ?? []),
      callback
    );
  },
  getPermissionWarningsByManifest(manifestStr: string, callback?: (warnings: string[]) => void) {
    return callbackify(
      () => gapCall<{ warnings?: string[] }>('management', 'getPermissionWarningsByManifest', { manifestStr }).then((r) => r?.warnings ?? []),
      callback
    );
  },
  // Lilo runs no apps: native answers these with Chrome's errors for a non-app. Some of them first
  // require a user gesture, which a service worker never has.
  launchApp: gapMethod('management', 'launchApp', ['id']),
  createAppShortcut(id: string, callback?: () => void) {
    return callbackify(() => gapCall<void>('management', 'createAppShortcut', { id, userGesture: hasUserGesture() }), callback);
  },
  setLaunchType(id: string, launchType: string, callback?: () => void) {
    return callbackify(() => gapCall<void>('management', 'setLaunchType', { id, launchType, userGesture: hasUserGesture() }), callback);
  },
  generateAppForLink(url: string, title: string, callback?: (result: any) => void) {
    return callbackify(() => gapCall('management', 'generateAppForLink', { url, title, userGesture: hasUserGesture() }), callback);
  },
  ...createGapEventsFromNames('management', ['onInstalled', 'onUninstalled', 'onEnabled', 'onDisabled']),
};
