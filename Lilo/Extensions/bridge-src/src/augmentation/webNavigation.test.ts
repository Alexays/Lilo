import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { webNavigationAugmentation } from './webNavigation.ts';
import { installGapAPIs } from '../shared/install-gap-apis.ts';
import { installChromeCompat } from '../shared/chrome-compat.ts';

describe('webNavigation same-document events', () => {
  it('resolves the tab id from the window position and index', async () => {
    (globalThis as any).chrome = {
      windows: { getAll: async () => [{ id: 10 }, { id: 20 }] },
      tabs: { query: async (q: any) => (q.windowId === 20 && q.index === 3 ? [{ id: 42 }] : []) },
    };
    const received = new Promise<any>((resolve) => webNavigationAugmentation.onHistoryStateUpdated.addListener(resolve));

    webNavigationAugmentation.onHistoryStateUpdated.dispatch({
      windowPosition: 1, index: 3, url: 'https://example.com/a', timeStamp: 1, transitionQualifiers: [],
    });

    const details = await received;
    assert.equal(details.tabId, 42);
    assert.equal(details.frameId, 0);
    assert.equal(details.url, 'https://example.com/a');
  });
});

describe('webNavigation tab resolution with tab groups', () => {
  it('queries WebKit directly, skipping the groupId lookup', async () => {
    const tab = { id: 5, index: 0, windowId: 1 };
    const query = async () => [tab];
    const tabs: any = { query, get: async () => tab };
    const chrome = { runtime: { getManifest: () => ({ permissions: ['tabGroups'] }) }, windows: { getAll: async () => [{ id: 1 }] }, tabs };
    installGapAPIs(chrome);
    (globalThis as any).chrome = chrome;
    installChromeCompat({});
    assert.notEqual(tabs.query, query, 'tabs.query adds group ids');
    const received = new Promise<any>((resolve) => webNavigationAugmentation.onHistoryStateUpdated.addListener(resolve));

    webNavigationAugmentation.onHistoryStateUpdated.dispatch({
      windowPosition: 0, index: 0, url: 'https://example.com/b', timeStamp: 1, transitionQualifiers: [],
    });

    assert.equal((await received).tabId, 5);
    assert.equal('groupId' in tab, false);
  });
});

describe('webNavigation url filters', () => {
  it('only calls a filtered listener for matching urls', async () => {
    (globalThis as any).chrome = {
      windows: { getAll: async () => [{ id: 1 }] },
      tabs: { query: async () => [{ id: 7 }] },
    };
    const event = webNavigationAugmentation.onReferenceFragmentUpdated;
    const heard: string[] = [];
    const all = new Promise<void>((resolve) => {
      (event as any).addListener((d: any) => { heard.push(`all ${d.url}`); if (heard.length === 3) resolve(); });
    });
    (event as any).addListener((d: any) => heard.push(`docs ${d.url}`), { url: [{ hostSuffix: 'example.com', pathPrefix: '/docs' }] });

    event.dispatch({ windowPosition: 0, index: 0, url: 'https://www.example.com/docs#a', timeStamp: 1, transitionQualifiers: [] } as any);
    event.dispatch({ windowPosition: 0, index: 0, url: 'https://other.org/docs#b', timeStamp: 2, transitionQualifiers: [] } as any);
    await all;

    assert.deepEqual(heard.sort(), [
      'all https://other.org/docs#b',
      'all https://www.example.com/docs#a',
      'docs https://www.example.com/docs#a',
    ]);
  });
});

describe('webNavigation.onCreatedNavigationTarget', () => {
  it('resolves the source and new tab ids from their positions', async () => {
    (globalThis as any).chrome = {
      runtime: { getManifest: () => ({ permissions: [] }) },
      windows: { getAll: async () => [{ id: 1 }] },
      tabs: { query: async (q: any) => [{ id: q.index === 0 ? 30 : 31 }] },
    };
    installChromeCompat({});
    const received = new Promise<any>((resolve) => webNavigationAugmentation.onCreatedNavigationTarget.addListener(resolve));

    webNavigationAugmentation.onCreatedNavigationTarget.dispatch({
      source: { windowPosition: 0, index: 0 }, tab: { windowPosition: 0, index: 1 }, url: 'https://example.com/new', timeStamp: 5,
    } as any);

    assert.deepEqual(await received, {
      sourceTabId: 30, sourceProcessId: -1, sourceFrameId: 0, url: 'https://example.com/new', tabId: 31, timeStamp: 5,
    });
  });
});

describe('webNavigation.onCommitted', () => {
  it("adds Chrome's transition details to WebKit's, passing the filter on", () => {
    class NativeEvent {
      listeners = new Map<(details: any) => void, unknown>();
      addListener(listener: (details: any) => void, filter?: unknown) { this.listeners.set(listener, filter); }
      removeListener(listener: (details: any) => void) { this.listeners.delete(listener); }
      hasListener(listener: (details: any) => void) { return this.listeners.has(listener); }
      fire(details: any) { for (const listener of this.listeners.keys()) listener(details); }
    }
    const onCommitted = new NativeEvent();
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ permissions: [] }) }, webNavigation: { onCommitted } };
    installChromeCompat({});
    const heard: any[] = [];
    const listener = (details: any) => heard.push(details);
    const filter = { url: [{ hostSuffix: 'example.com' }] };

    (globalThis as any).chrome.webNavigation.onCommitted.addListener(listener, filter);
    assert.deepEqual([...onCommitted.listeners.values()], [filter]);
    assert.equal(onCommitted.hasListener(listener), true);
    onCommitted.fire({ tabId: 1, frameId: 0, url: 'https://example.com/' });
    onCommitted.fire({ tabId: 1, frameId: 7, url: 'https://example.com/frame' });
    assert.deepEqual(heard.map((d) => [d.frameId, d.transitionType, d.transitionQualifiers]), [[0, 'link', []], [7, 'auto_subframe', []]]);

    onCommitted.removeListener(listener);
    assert.equal(onCommitted.listeners.size, 0);
    assert.equal(onCommitted.hasListener(listener), false);
  });
});

describe('webNavigation load events', () => {
  it('skip extension pages past their commit, as Chrome', () => {
    class NativeEvent {
      listeners = new Set<(details: any) => void>();
      addListener(listener: (details: any) => void) { this.listeners.add(listener); }
      removeListener(listener: (details: any) => void) { this.listeners.delete(listener); }
      fire(details: any) { for (const listener of this.listeners) listener(details); }
    }
    const onDOMContentLoaded = new NativeEvent();
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ permissions: [] }) }, webNavigation: { onDOMContentLoaded } };
    installChromeCompat({});
    const heard: string[] = [];
    (globalThis as any).chrome.webNavigation.onDOMContentLoaded.addListener((details: any) => heard.push(details.url));
    onDOMContentLoaded.fire({ tabId: 1, frameId: 0, url: 'chrome-extension://abc/popup.html' });
    onDOMContentLoaded.fire({ tabId: 2, frameId: 0, url: 'https://example.com/' });
    assert.deepEqual(heard, ['https://example.com/']);
  });
});
