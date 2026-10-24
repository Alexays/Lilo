import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const calls: any[] = [];
let userActivation = false;
const windows = [{ id: 10 }, { id: 20 }];
const tabs = [{ id: 7, windowId: 20, index: 1 }];

mockGapAPI((msg) => { calls.push(msg); return null; });
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { get userActivation() { return { isActive: userActivation }; } } });
(globalThis as any).chrome = {
  windows: { getAll: async () => windows, getCurrent: async () => windows[1] },
  tabs: {
    get: async (id: number) => {
      const tab = tabs.find((t) => t.id === id);
      if (!tab) throw new Error('No tab');
      return tab;
    },
    query: async ({ windowId, index }: any) => tabs.filter((t) => t.windowId === windowId && t.index === index),
  },
};

const { sidePanelAugmentation } = await import('./sidePanel.ts');
const lastCall = (method: string) => calls.filter((c) => c.namespace === 'sidePanel' && c.method === method).at(-1)?.params;

describe('chrome.sidePanel', () => {
  it('sends open its tab position and whether the page has a user gesture', async () => {
    userActivation = true;
    await sidePanelAugmentation.open({ tabId: 7 });

    assert.deepEqual(lastCall('open'), { tabId: 7, windowId: undefined, tab: { windowPosition: 1, index: 1 }, userGesture: true });
  });

  it('resolves the current window and marks an unknown one', async () => {
    userActivation = false;
    await sidePanelAugmentation.close({ windowId: -2 });
    assert.equal(lastCall('close').windowPosition, 1);

    await sidePanelAugmentation.open({ windowId: 99 });
    assert.equal(lastCall('open').windowPosition, -1);
    assert.equal(lastCall('open').userGesture, false);
  });

  it('leaves out the position of an unknown tab, for native to name it', async () => {
    await sidePanelAugmentation.close({ tabId: 404 });

    assert.equal(lastCall('close').tab, undefined);
    assert.equal(lastCall('close').tabId, 404);
  });

  it('reports a tab-specific panel with its window and tab ids', async () => {
    const opened = new Promise<any>((resolve) => sidePanelAugmentation.onOpened.addListener(resolve));
    sidePanelAugmentation.onOpened.dispatch({ windowPosition: 1, index: 1, path: '/panel.html' });

    assert.deepEqual(await opened, { windowId: 20, tabId: 7, path: '/panel.html' });
  });

  it('reports a closed window as -1', async () => {
    const closed = new Promise<any>((resolve) => sidePanelAugmentation.onClosed.addListener(resolve));
    sidePanelAugmentation.onClosed.dispatch({ windowPosition: -1, path: '/panel.html' });

    assert.deepEqual(await closed, { windowId: -1, path: '/panel.html' });
  });

  it('docks on the right', async () => {
    assert.deepEqual(await sidePanelAugmentation.getLayout(), { side: 'right' });
  });
});
