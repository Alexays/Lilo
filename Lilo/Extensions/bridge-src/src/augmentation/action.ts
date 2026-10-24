// Augments the native chrome.action with gap-bridged badge color calls.
// WK handles setBadgeText natively; only color methods are handled here.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { tabPositions } from './tabGroups.ts';

function colorToString(color: string | number[]): string {
  if (typeof color === 'string') return color;
  const [r, g, b] = color as number[];
  const a = (color as number[])[3] ?? 255;
  return `rgba(${r},${g},${b},${(a / 255).toFixed(3)})`;
}

/**
 * Parse the CSS color string the native side stores back into Chrome's ColorArray ([r,g,b,a],
 * each channel 0-255), so `getBadge*Color` matches the spec (extensions destructure the result).
 */
function colorToArray(css: string): [number, number, number, number] {
  const s = (css ?? '').trim();
  if (!s) return [0, 0, 0, 0];
  const rgba = s.match(/^rgba?\(([^)]+)\)$/i);
  if (rgba) {
    const parts = rgba[1].split(',').map((p) => p.trim());
    const r = parseInt(parts[0], 10) || 0;
    const g = parseInt(parts[1], 10) || 0;
    const b = parseInt(parts[2], 10) || 0;
    const a = parts[3] !== undefined ? Math.round((parseFloat(parts[3]) || 0) * 255) : 255;
    return [r, g, b, Math.max(0, Math.min(255, a))];
  }
  const hex = s.match(/^#([0-9a-f]{3,8})$/i);
  if (hex) {
    let h = hex[1];
    if (h.length === 3 || h.length === 4) {
      h = h.split('').map((c) => c + c).join('');
    }
    return [
      parseInt(h.slice(0, 2), 16),
      parseInt(h.slice(2, 4), 16),
      parseInt(h.slice(4, 6), 16),
      h.length >= 8 ? parseInt(h.slice(6, 8), 16) : 255,
    ];
  }
  return [0, 0, 0, 0];
}

export const actionColorAugmentation = {
  setBadgeBackgroundColor(
    details: { color: string | number[]; tabId?: number },
    callback?: () => void
  ) {
    const color = colorToString(details.color);
    return callbackify(
      async () => gapCall<null>('action', 'setBadgeBackgroundColor', {
        color,
        tabId: details.tabId,
        // The toolbar shows Lilo tabs, which native finds by position.
        tabs: details.tabId === undefined ? undefined : await tabPositions([details.tabId]),
      }),
      callback
    );
  },

  getBadgeBackgroundColor(
    details: { tabId?: number },
    callback?: (color: [number, number, number, number]) => void
  ) {
    return callbackify(
      () => gapCall<string>('action', 'getBadgeBackgroundColor', details).then(colorToArray),
      callback
    );
  },

  setBadgeTextColor(
    details: { color: string | number[]; tabId?: number },
    callback?: () => void
  ) {
    const color = colorToString(details.color);
    return callbackify(
      async () => gapCall<null>('action', 'setBadgeTextColor', {
        color,
        tabId: details.tabId,
        // The toolbar shows Lilo tabs, which native finds by position.
        tabs: details.tabId === undefined ? undefined : await tabPositions([details.tabId]),
      }),
      callback
    );
  },

  getBadgeTextColor(
    details: { tabId?: number },
    callback?: (color: [number, number, number, number]) => void
  ) {
    return callbackify(
      () => gapCall<string>('action', 'getBadgeTextColor', details).then(colorToArray),
      callback
    );
  },

  // On the toolbar means pinned to the address bar.
  getUserSettings(callback?: (settings: { isOnToolbar: boolean }) => void) {
    return callbackify(() => gapCall<{ isOnToolbar: boolean }>('action', 'getUserSettings'), callback);
  },

  // Opens this extension's popup, reusing the same native path as the toolbar button.
  openPopup(options?: any, callback?: () => void) {
    const cb = typeof options === 'function' ? options : callback;
    return callbackify(
      () => gapCall<null>('action', 'openPopup'),
      cb
    );
  },
};
