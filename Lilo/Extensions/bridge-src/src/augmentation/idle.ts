import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';

export const idleAugmentation = {
  queryState(detectionIntervalInSeconds: number, callback?: (newState: string) => void) {
    return callbackify(
      () => gapCall<string>('idle', 'queryState', { detectionIntervalInSeconds }),
      callback
    );
  },
  setDetectionInterval(intervalInSeconds: number) {
    gapCall<void>('idle', 'setDetectionInterval', { intervalInSeconds }).catch(() => {});
  },
  ...createGapEventsFromNames('idle', ['onStateChanged']),
};
