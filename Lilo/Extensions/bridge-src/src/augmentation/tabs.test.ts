import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return Promise.resolve(typeof nextResult === 'function' ? nextResult(msg.params) : nextResult);
});

const tabs = [
  { id: 11, index: 0, windowId: 1, active: true },
  { id: 12, index: 1, windowId: 1, active: false },
];
const updates: Array<[number, unknown]> = [];

function installChrome(): void {
  (globalThis as any).chrome = {
    windows: {
      getAll: async () => [{ id: 1 }],
      getCurrent: async () => ({ id: 1 }),
      get: async (id: number, info?: { populate?: boolean }) => {
        if (id !== 1) throw new Error('Invalid window');
        return info?.populate ? { id: 1, tabs } : { id: 1 };
      },
    },
    tabs: {
      get: async (id: number) => {
        const tab = tabs.find((t) => t.id === id);
        if (!tab) throw new Error('Invalid tab');
        return tab;
      },
      query: async (q: any) => tabs.filter((t) => (q.index === undefined || t.index === q.index) && (!q.active || t.active)),
      update: async (id: number, props: unknown) => { updates.push([id, props]); },
    },
  };
}

const { tabsAdditions, onBoundsChanged } = await import('./tabs.ts');
const { installChromeCompat } = await import('../shared/chrome-compat.ts');

beforeEach(() => {
  installChrome();
  gapCalls.length = 0;
  updates.length = 0;
});

describe('tabs.highlight', () => {
  it('activates the first given tab and resolves with the populated window', async () => {
    const highlighted = await tabsAdditions.highlight({ tabs: [1, 0] });

    assert.deepEqual(updates, [[12, { active: true }]]);
    assert.deepEqual(highlighted, { id: 1, tabs });
  });

  it('fails with Chrome errors for a missing index or window', async () => {
    await assert.rejects(tabsAdditions.highlight({ tabs: 5 }) as Promise<unknown>, { message: 'No tab at index: 5.' });
    await assert.rejects(tabsAdditions.highlight({ windowId: 9, tabs: 0 }) as Promise<unknown>, { message: 'No window with id: 9.' });
    await assert.rejects(tabsAdditions.highlight({ tabs: [] }) as Promise<unknown>, { message: 'No highlighted tab' });
  });
});

describe('tabs zoom settings', () => {
  it('sends the active tab position when no tab id is given', async () => {
    nextResult = { mode: 'automatic', scope: 'per-origin', defaultZoomFactor: 1 };

    const settings = await tabsAdditions.getZoomSettings();

    assert.deepEqual(settings, nextResult);
    assert.deepEqual(gapCalls[0].params, { tab: { windowPosition: 0, index: 0 } });
  });

  it('rejects per-origin scope outside automatic mode, as Chrome does', async () => {
    await assert.rejects(
      tabsAdditions.setZoomSettings(12, { mode: 'manual', scope: 'per-origin' }) as Promise<void>,
      { message: 'Can only set scope to "per-origin" in "automatic" mode.' },
    );
    assert.equal(gapCalls.length, 0);
  });

  it('accepts settings without a tab id', async () => {
    nextResult = null;

    await tabsAdditions.setZoomSettings({ mode: 'disabled' });

    assert.deepEqual(gapCalls[0].params, { tab: { windowPosition: 0, index: 0 }, mode: 'disabled', scope: undefined });
  });

  it('resolves onZoomChange to the tab id', async () => {
    const heard = new Promise<any>((resolve) => tabsAdditions.onZoomChange.addListener(resolve));

    tabsAdditions.onZoomChange.dispatch({
      windowPosition: 0, index: 1, oldZoomFactor: 1, newZoomFactor: 1.5, zoomSettings: { mode: 'automatic', scope: 'per-origin' },
    });

    assert.deepEqual(await heard, { tabId: 12, oldZoomFactor: 1, newZoomFactor: 1.5, zoomSettings: { mode: 'automatic', scope: 'per-origin' } });
  });
});

describe('tabs split views', () => {
  it('rejects duplicate and unknown tab ids before reaching native', async () => {
    await assert.rejects(tabsAdditions.createSplit([11, 11]) as Promise<number>, { message: 'Cannot create a split view with duplicate tab IDs.' });
    await assert.rejects(tabsAdditions.createSplit([11, 99]) as Promise<number>, { message: 'No tab with id: 99.' });
    assert.equal(gapCalls.length, 0);
  });

  it('sends both tab positions and ids', async () => {
    nextResult = 3;

    assert.equal(await tabsAdditions.createSplit([11, 12]), 3);
    assert.deepEqual(gapCalls[0].params, { tabs: [{ windowPosition: 0, index: 0 }, { windowPosition: 0, index: 1 }], tabIds: [11, 12] });
  });
});

describe('tab positions', () => {
  it('looks every tab and the window order up at once, dropping unknown ids', async () => {
    const chrome = (globalThis as any).chrome;
    const { get } = chrome.tabs;
    const { getAll } = chrome.windows;
    const started: string[] = [];
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    chrome.tabs.get = async (id: number) => { started.push(`tab ${id}`); await gate; return get(id); };
    chrome.windows.getAll = async () => { started.push('windows'); await gate; return getAll(); };
    const { tabPositions } = await import('./tabGroups.ts');

    const positions = tabPositions([12, 99, 11]);

    assert.deepEqual(started.sort(), ['tab 11', 'tab 12', 'tab 99', 'windows']);
    release();
    assert.deepEqual(await positions, [{ windowPosition: 0, index: 1 }, { windowPosition: 0, index: 0 }]);
  });
});

describe('windows.onBoundsChanged', () => {
  it('resolves the window from its position', async () => {
    const heard = new Promise<any>((resolve) => onBoundsChanged.addListener(resolve));

    onBoundsChanged.dispatch({ windowPosition: 0 });

    assert.deepEqual(await heard, { id: 1 });
  });
});

describe("Chrome's Tab objects", () => {
  class NativeEvent {
    listeners = new Set<(...args: any[]) => void>();
    addListener(listener: (...args: any[]) => void) { this.listeners.add(listener); }
    removeListener(listener: (...args: any[]) => void) { this.listeners.delete(listener); }
    hasListener(listener: (...args: any[]) => void) { return this.listeners.has(listener); }
    fire(...args: any[]) { for (const listener of this.listeners) listener(...args); }
  }

  /** Lilo's answer for a loaded tab outside any group; with `reveal`, the url and title of the revealed tabs. */
  const details = (extra: object = {}) => (params: any) => params.tabs.map((_: unknown, i: number) => ({
    groupId: -1, discarded: false, frozen: false, lastAccessed: 5,
    ...(params.reveal.includes(i) ? { url: 'chrome://newtab/', title: 'New Tab' } : {}),
    ...extra,
  }));
  const chromeFields = { groupId: -1, discarded: false, frozen: false, autoDiscardable: true };

  function install(permissions: string[], tabs: () => any[] = () => [{ id: 11, index: 0, windowId: 1, url: '', title: '', status: 'loading' }]) {
    const asked: unknown[] = [];
    class Tabs { query(info: unknown) { asked.push(info); return Promise.resolve(tabs()); } }
    const webKit = Object.assign(new Tabs(), { onCreated: new NativeEvent(), onUpdated: new NativeEvent() });
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ permissions }) }, tabs: webKit };
    installChromeCompat({});
    return { chrome: (globalThis as any).chrome, webKit, withheld: () => tabs()[0], asked };
  }

  it('leave out the url and title WebKit withholds as "" for an extension that may not hold tabs, as Chrome', async () => {
    nextResult = details();
    const { chrome, webKit, withheld } = install([]);
    const left = { id: 11, index: 0, windowId: 1, status: 'loading', ...chromeFields };
    assert.deepEqual(await chrome.tabs.query({}), [{ ...left, lastAccessed: 5 }]);
    assert.deepEqual(gapCalls, [{ namespace: 'tabs', method: 'details', params: { tabs: [{ windowPosition: -1, index: 0 }], reveal: [] } }]);
    const heard: unknown[] = [];
    const onUpdated = (...args: unknown[]) => heard.push(args);
    chrome.tabs.onUpdated.addListener(onUpdated);
    webKit.onUpdated.fire(11, { title: '' }, withheld());
    webKit.onUpdated.fire(11, { status: 'complete', url: '' }, withheld());
    assert.deepEqual(heard, [[11, {}, left], [11, { status: 'complete' }, left]]);
    chrome.tabs.onUpdated.removeListener(onUpdated);
    assert.equal(webKit.onUpdated.listeners.size, 0);
  });

  it("read the withheld url and title from Lilo for an extension that holds tabs, an empty tab as Chrome's new tab page", async () => {
    nextResult = details();
    const { chrome, webKit, withheld } = install(['tabs']);
    assert.deepEqual(await chrome.tabs.query({}), [{ ...withheld(), url: 'chrome://newtab/', title: 'New Tab', ...chromeFields, lastAccessed: 5 }]);
    assert.deepEqual(gapCalls, [{ namespace: 'tabs', method: 'details', params: { tabs: [{ windowPosition: -1, index: 0 }], reveal: [0] } }]);
    const heard: unknown[] = [];
    chrome.tabs.onUpdated.addListener((...args: unknown[]) => heard.push(args));
    webKit.onUpdated.fire(11, { title: '' }, withheld());
    assert.deepEqual(heard, [[11, { title: '' }, { ...withheld(), ...chromeFields }]]);
  });

  it('leave out the url and title of a tab Lilo does not hold, such as the stand-in of a window showing no web page', async () => {
    nextResult = () => [null];
    const { chrome } = install(['tabs']);
    assert.deepEqual(await chrome.tabs.query({}), [{ id: 11, index: 0, windowId: 1, status: 'loading', ...chromeFields }]);
  });

  it('report an unloaded tab as discarded, its status unloaded, as Chrome', async () => {
    nextResult = details({ discarded: true });
    const { chrome } = install([], () => [{ id: 11, index: 0, windowId: 1, status: 'complete' }]);
    const [tab] = await chrome.tabs.query({});
    assert.equal(tab.discarded, true);
    assert.equal(tab.status, 'unloaded');
  });

  it('filter tabs.query on groupId, which WebKit ignores', async () => {
    nextResult = () => [{ groupId: 4 }, { groupId: -1 }];
    const { chrome, asked } = install([], () => [{ id: 11, index: 0, windowId: 1 }, { id: 12, index: 1, windowId: 1 }]);
    assert.deepEqual((await chrome.tabs.query({ groupId: 4, active: true })).map((tab: any) => tab.id), [11]);
    assert.deepEqual(asked, [{ active: true }]);
  });

  it('give a new tab Chrome\'s fields in tabs.onCreated, last accessed when made', () => {
    const { chrome, webKit } = install([]);
    const heard: any[] = [];
    chrome.tabs.onCreated.addListener((tab: unknown) => heard.push(tab));
    const before = Date.now();
    webKit.onCreated.fire({ id: 13, index: 1, windowId: 1, url: 'https://example.com/', title: 'Example', status: 'loading' });
    const { lastAccessed, ...rest } = heard[0];
    assert.deepEqual(rest, { id: 13, index: 1, windowId: 1, url: 'https://example.com/', title: 'Example', status: 'loading', ...chromeFields });
    assert.ok(lastAccessed >= before && lastAccessed <= Date.now());
  });

  it("match chrome:// url patterns, which WebKit rejects, against Chrome's new tab page", async () => {
    const pages = [{ id: 11, index: 0, windowId: 1, url: '', title: '' }, { id: 12, index: 1, windowId: 1, url: 'https://example.com/', title: 'Example' }];
    class Tabs {
      query(info: any) {
        const patterns = [info?.url ?? []].flat();
        if (patterns.some((pattern: string) => pattern.startsWith('chrome://'))) return Promise.reject(new Error(`'${patterns[0]}' is not a valid pattern.`));
        return Promise.resolve(structuredClone(patterns.length ? pages.filter((tab) => tab.url.startsWith('https://example.com/')) : pages));
      }
    }
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ permissions: ['tabs'] }) }, tabs: Object.assign(new Tabs(), { onCreated: new NativeEvent(), onUpdated: new NativeEvent() }) };
    installChromeCompat({});
    const chrome = (globalThis as any).chrome;
    nextResult = details();

    assert.deepEqual((await chrome.tabs.query({ url: 'chrome://newtab/*' })).map((tab: any) => tab.id), [11]);
    assert.deepEqual((await chrome.tabs.query({ url: ['https://example.com/*', 'chrome://newtab/*'] })).map((tab: any) => tab.id), [11, 12]);
    assert.deepEqual(await new Promise((resolve) => chrome.tabs.query({ url: 'chrome://extensions/*' }, resolve)), []);
  });
});
