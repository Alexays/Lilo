import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const views = [
  { contextType: 'POPUP', url: 'chrome-extension://ext/popup.html' },
  { contextType: 'SIDE_PANEL', url: 'chrome-extension://ext/panel.html' },
];

mockGapAPI((msg) => (msg.namespace === 'runtime' && msg.method === 'extensionViews' ? views : null));
(globalThis as any).chrome = {
  runtime: {
    getManifest: () => ({ background: { service_worker: 'sw.js' } }),
    getURL: (path: string) => `chrome-extension://ext/${path}`,
  },
  tabs: { query: async () => [] },
};

const { getContexts } = await import('./offscreen.ts');

describe('runtime.getContexts', () => {
  it('lists the popup and side panel native reports beside the background', async () => {
    const contexts = (await getContexts()) as any[];

    assert.deepEqual(contexts.map((c) => c.contextType), ['BACKGROUND', 'POPUP', 'SIDE_PANEL']);
    assert.equal(contexts[2].documentUrl, 'chrome-extension://ext/panel.html');
  });

  it('filters by context type', async () => {
    const contexts = (await getContexts({ contextTypes: ['POPUP'] })) as any[];

    assert.deepEqual(contexts.map((c) => c.documentUrl), ['chrome-extension://ext/popup.html']);
  });
});
