// chrome.commands gap bridge.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';

export const commandsAugmentation = {
  getAll(callback?: (commands: any[]) => void) {
    return callbackify(() => gapCall<{ commands?: any[] }>('commands', 'getAll').then((r) => r?.commands ?? []), callback);
  },
  ...createGapEventsFromNames('commands', ['onCommand']),
};
