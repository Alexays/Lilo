// chrome.system.cpu, .memory, .storage and .display, each installed with its own permission.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames, gapMethod } from '../shared/gap-event.ts';

const CROS_ONLY = 'Function available only on ChromeOS.';

/** A display call Chrome rejects off ChromeOS: async ones reject, the others log as an unchecked lastError. */
function crosOnly(callback?: (...args: any[]) => void) {
  return callbackify(() => Promise.reject(new Error(CROS_ONLY)), callback);
}

function crosOnlyUnchecked() {
  console.error(`Unchecked runtime.lastError: ${CROS_ONLY}`);
}

export const systemCpuAugmentation = {
  getInfo: gapMethod('system.cpu', 'getInfo'),
};

export const systemMemoryAugmentation = {
  getInfo: gapMethod('system.memory', 'getInfo'),
};

export const systemStorageAugmentation = {
  getInfo: gapMethod('system.storage', 'getInfo'),
  ejectDevice: gapMethod('system.storage', 'ejectDevice', ['id']),
  ...createGapEventsFromNames('system.storage', ['onAttached', 'onDetached']),
};

export const systemDisplayAugmentation = {
  // flags.singleUnified only concerns ChromeOS's unified desktop.
  getInfo(flags?: unknown, callback?: (info: any[]) => void) {
    return callbackify(() => gapCall<any[]>('system.display', 'getInfo'), typeof flags === 'function' ? flags as typeof callback : callback);
  },
  getDisplayLayout: (callback?: () => void) => crosOnly(callback),
  setDisplayProperties: (_id: string, _info: unknown, callback?: () => void) => crosOnly(callback),
  setDisplayLayout: (_layouts: unknown, callback?: () => void) => crosOnly(callback),
  showNativeTouchCalibration: (_id: string, callback?: () => void) => crosOnly(callback),
  setMirrorMode: (_info: unknown, callback?: () => void) => crosOnly(callback),
  enableUnifiedDesktop: crosOnlyUnchecked,
  overscanCalibrationStart: crosOnlyUnchecked,
  overscanCalibrationAdjust: crosOnlyUnchecked,
  overscanCalibrationReset: crosOnlyUnchecked,
  overscanCalibrationComplete: crosOnlyUnchecked,
  startCustomTouchCalibration: crosOnlyUnchecked,
  completeCustomTouchCalibration: crosOnlyUnchecked,
  clearTouchCalibration: crosOnlyUnchecked,
  ...createGapEventsFromNames('system.display', ['onDisplayChanged']),
};
