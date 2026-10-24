import { gapCall } from '../shared/ipc.ts';

// Both return nothing in Chrome: native holds one request per extension until released or unloaded.
export const powerAugmentation = {
  requestKeepAwake(level: 'system' | 'display') {
    if (level !== 'system' && level !== 'display') {
      throw new TypeError("Error in invocation of power.requestKeepAwake(power.Level level): Error at parameter 'level': Value must be one of display, system.");
    }
    gapCall<void>('power', 'requestKeepAwake', { level }).catch(() => {});
  },
  releaseKeepAwake() {
    gapCall<void>('power', 'releaseKeepAwake').catch(() => {});
  },
};
