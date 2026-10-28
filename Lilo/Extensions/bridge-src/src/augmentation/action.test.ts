import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const stored: Record<string, unknown> = {};

mockGapAPI((msg: any) => {
  if (msg.method.startsWith('set')) stored[msg.method.slice(3)] = msg.params.color;
  return msg.method.startsWith('get') ? stored[msg.method.slice(3)] ?? '' : null;
});

(globalThis as any).chrome = { runtime: {} };

// Node has no canvas: this one serializes the colors below as WebKit does, and ignores any other value.
const serialized: Record<string, string> = {
  '#000000': '#000000', '#ffffff': '#ffffff', red: '#ff0000', 'hsl(120 100% 50%)': '#00ff00', 'rgb(255 0 0 / 50%)': 'rgba(255, 0, 0, 0.5)',
};
(globalThis as any).OffscreenCanvas = class {
  getContext() {
    let fillStyle = '#000000';
    return {
      get fillStyle() { return fillStyle; },
      set fillStyle(value: string) { fillStyle = serialized[value] ?? fillStyle; },
    };
  }
};

const { actionColorAugmentation } = await import('./action.ts');

describe('action badge colors', () => {
  it('reads back a CSS color as the ColorArray Chrome gives', async () => {
    await actionColorAugmentation.setBadgeBackgroundColor({ color: 'red' });
    assert.deepEqual(await actionColorAugmentation.getBadgeBackgroundColor({}), [255, 0, 0, 255]);

    await actionColorAugmentation.setBadgeBackgroundColor({ color: 'hsl(120 100% 50%)' });
    assert.deepEqual(await actionColorAugmentation.getBadgeBackgroundColor({}), [0, 255, 0, 255]);

    await actionColorAugmentation.setBadgeTextColor({ color: 'rgb(255 0 0 / 50%)' });
    assert.deepEqual(await actionColorAugmentation.getBadgeTextColor({}), [255, 0, 0, 128]);
  });

  it("rejects a color it cannot parse with Chrome's error, keeping the color set before", async () => {
    await actionColorAugmentation.setBadgeBackgroundColor({ color: 'red' });

    await assert.rejects(
      actionColorAugmentation.setBadgeBackgroundColor({ color: 'not a color' })!,
      { message: 'The color specification could not be parsed.' },
    );
    assert.deepEqual(await actionColorAugmentation.getBadgeBackgroundColor({}), [255, 0, 0, 255]);
  });
});
