import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { installChromeCompat } from './chrome-compat.ts';
import { mockGapAPI } from './ipc.testkit.ts';

declare const chrome: any;

/** Lilo's answers to the permissions calls, and the calls it got. */
let held: string[] = [];
let granted = true;
const liloCalls: Array<{ method: string; params: any }> = [];
mockGapAPI(({ namespace, method, params }) => {
  if (namespace !== 'permissions') return null;
  liloCalls.push({ method, params });
  return method === 'held' ? held : method === 'request' ? granted : true;
});

// WebKit's namespace and event objects keep their methods on a prototype; the messages are the ones
// extensions hit.
function install(namespaces: Record<string, unknown>, permissions: string[] = [], optional: string[] = []): any {
  const runtime = { getManifest: () => ({ permissions, optional_permissions: optional }), ...(namespaces.runtime as object) };
  (globalThis as any).chrome = { ...namespaces, runtime };
  installChromeCompat({});
  return (globalThis as any).chrome;
}

function rejectUnknown(known: Set<string>) {
  return (request: { permissions?: string[] }) => {
    const unknown = request.permissions?.find((name) => !known.has(name));
    if (unknown) throw new Error(`Invalid call to permissions.contains(). The 'permissions' value is invalid, because '${unknown}' is not a valid permission.`);
    return Promise.resolve(true);
  };
}

describe('permissions with names WebKit does not know', () => {
  const known = new Set(['tabs']);
  const { permissions } = install({
    permissions: Object.create({
      contains: rejectUnknown(known),
      request: rejectUnknown(known),
      remove: rejectUnknown(known),
      getAll: async () => ({ permissions: ['tabs'], origins: [] }),
    }),
  }, ['tabs', 'tabGroups']);

  it('answers from the manifest for the unknown ones', async () => {
    assert.equal(await permissions.contains({ permissions: ['tabs', 'tabGroups'] }), true);
    assert.equal(await permissions.contains({ permissions: ['tabs', 'debugger'] }), false);
  });

  it('refuses to remove a required one, as Chrome does', async () => {
    await assert.rejects(permissions.remove({ permissions: ['tabGroups'] }), /You cannot remove required permissions/);
  });

  it('lists every declared permission', async () => {
    assert.deepEqual((await permissions.getAll()).permissions.sort(), ['tabGroups', 'tabs']);
  });
});

describe('webRequest filters WebKit rejects', () => {
  function webRequestEvent() {
    const added: unknown[] = [];
    const prototype = {
      addListener(_listener: unknown, filter: { urls: string[]; types?: string[] }) {
        if (filter.types?.includes('webbundle')) throw new Error("Invalid call to addListener(). The 'types' value is invalid, because 'webbundle' is an unknown resource type.");
        const ws = filter.urls.find((url) => url.startsWith('ws'));
        if (ws) throw new Error(`Invalid call to addListener(). The 'urls' value is invalid, because '${ws}' is an invalid match pattern.`);
        added.push(filter);
      },
    };
    const event = install({ webRequest: { onBeforeRequest: Object.create(prototype) } }).webRequest.onBeforeRequest;
    return { event, added };
  }

  it('drops the unknown types and patterns', () => {
    const { event, added } = webRequestEvent();
    event.addListener(() => {}, { urls: ['<all_urls>', 'ws://*/*'], types: ['main_frame', 'webbundle'] });
    assert.deepEqual(added, [{ urls: ['<all_urls>'], types: ['main_frame'] }]);
  });

  it('registers nothing when no pattern is left', () => {
    const { event, added } = webRequestEvent();
    event.addListener(() => {}, { urls: ['ws://*/*', 'wss://*/*'] });
    assert.deepEqual(added, []);
  });
});

describe('hasListeners, which WebKit events lack', () => {
  it('follows the listeners each event holds', () => {
    const prototype = { addListener(_listener: unknown) {}, removeListener(_listener: unknown) {} };
    const first: any = Object.create(prototype);
    const second: any = Object.create(prototype);
    install({ runtime: { onMessage: first } });
    const listener = () => {};
    assert.equal(first.hasListeners(), false);
    first.addListener(listener);
    assert.equal(first.hasListeners(), true);
    assert.equal(second.hasListeners(), false);
    first.removeListener(listener);
    assert.equal(first.hasListeners(), false);
  });

  it('ignores a listener that is not a function, as Chrome does', () => {
    const refuse = (listener?: unknown) => {
      if (typeof listener !== 'function') throw new Error("Invalid call to removeListener(). The 'listener' value is invalid, because a function is expected.");
    };
    const event: any = Object.create({ addListener: refuse, removeListener: refuse, hasListener: refuse });
    install({ runtime: { onMessage: event } });
    assert.equal(event.addListener(undefined), undefined);
    assert.equal(event.removeListener(null), undefined);
    assert.equal(event.hasListener('a'), false);
    assert.equal(event.hasListeners(), false);
  });

  it('reaches every event prototype the namespaces expose', () => {
    class NavigationEvent { addListener() {} }
    class WindowEvent { addListener() {} }
    const chrome = install({
      webNavigation: Object.create({ onCommitted: new NavigationEvent() }),
      windows: { onCreated: new WindowEvent(), onRemoved: new WindowEvent() },
    });
    assert.equal(chrome.webNavigation.onCommitted.hasListeners(), false);
    assert.equal(typeof (new NavigationEvent() as any).hasListeners, 'function', 'browser.webNavigation events have it too');
    assert.equal(chrome.windows.onRemoved.hasListeners(), false);
  });
});

describe('context menus with MV2 action contexts', () => {
  it('turns them into the action context', () => {
    const created: unknown[] = [];
    const updated: unknown[] = [];
    const { contextMenus: menus } = install({
      contextMenus: Object.create({
        create(properties: unknown) { created.push(properties); },
        update(_id: unknown, properties: unknown) { updated.push(properties); },
      }),
    });
    menus.create({ id: 'a', contexts: ['browser_action', 'action', 'page'] });
    menus.update('a', { contexts: ['page_action'] });
    menus.create({ id: 'b', title: 't' });
    assert.deepEqual(created, [{ id: 'a', contexts: ['action', 'page'] }, { id: 'b', title: 't' }]);
    assert.deepEqual(updated, [{ contexts: ['action'] }]);
  });
});

describe('context menus WebKit rejects', () => {
  function menus() {
    const created: any[] = [];
    const updated: any[] = [];
    const check = (method: string, properties: any) => {
      for (const key of ['documentUrlPatterns', 'targetUrlPatterns']) {
        const rejected = properties[key]?.find((pattern: string) => !/^(https?|\*|chrome-extension):\/\//.test(pattern));
        if (rejected !== undefined) throw new Error(`Invalid call to menus.${method}(). The '${key}' value is invalid, because '${rejected}' is not a valid pattern.`);
      }
    };
    const { contextMenus } = install({
      contextMenus: Object.create({
        create(properties: any) {
          if (properties.title === undefined && properties.type !== 'separator') throw new Error("Invalid call to menus.create(). The 'properties' value is invalid, because it is missing required keys: 'title'.");
          if (properties.title === '') throw new Error("Invalid call to menus.create(). The 'title' value is invalid, because it must not be empty.");
          check('create', properties);
          created.push(properties);
          return properties.id;
        },
        update(_id: unknown, properties: any) { check('update', properties); updated.push(properties); },
      }),
    });
    return { contextMenus, created, updated };
  }

  it('drops the URL patterns WebKit rejects', () => {
    const { contextMenus, created, updated } = menus();
    assert.equal(contextMenus.create({ id: 'a', title: 'A', documentUrlPatterns: ['ftp://*/*', 'https://*/*', 'urn:*'], targetUrlPatterns: ['https://a.com/*'] }), 'a');
    contextMenus.update('a', { targetUrlPatterns: ['data:*', 'http://*/*'] });
    assert.deepEqual(created, [{ id: 'a', title: 'A', documentUrlPatterns: ['https://*/*'], targetUrlPatterns: ['https://a.com/*'] }]);
    assert.deepEqual(updated, [{ targetUrlPatterns: ['http://*/*'] }]);
  });

  it('keeps an item under the parent it already has, which WebKit refuses as an ancestor', async () => {
    const updated: any[] = [];
    const { contextMenus } = install({
      contextMenus: Object.create({
        async update(id: string, properties: any) {
          if (properties.parentId !== undefined) throw new Error('Invalid call to menus.update(). Parent menu item cannot be itself or another ancestor.');
          updated.push([id, properties]);
        },
      }),
    });
    await contextMenus.update('child', { parentId: 'parent', title: 'T' });
    assert.deepEqual(updated, [['child', { title: 'T' }]]);
    await assert.rejects(contextMenus.update('child', { parentId: 'child' }), /cannot be itself/);
  });

  it('reads a null parentId as none, as Chrome', () => {
    const { contextMenus, created } = menus();
    contextMenus.create({ id: 'a', title: 'A', parentId: null });
    assert.deepEqual(created, [{ id: 'a', title: 'A' }]);
  });

  it('matches nothing when no pattern is left, as Chrome in Lilo', () => {
    const { contextMenus, created } = menus();
    contextMenus.create({ id: 'a', title: 'A', documentUrlPatterns: ['ftp://*/*'] });
    assert.deepEqual(created, [{ id: 'a', title: 'A', documentUrlPatterns: ['chrome-extension://invalid/*'] }]);
  });

  it('creates no item without a title and reports it as Chrome does', async () => {
    const { contextMenus, created } = menus();
    const reported: unknown[] = [];
    const error = console.error;
    console.error = (message: unknown) => { reported.push(message); };
    try {
      assert.equal(contextMenus.create({ id: 'a' }), 'a');
    } finally {
      console.error = error;
    }
    assert.deepEqual(reported, ['Unchecked runtime.lastError: All menu items except for separators must have a title']);
    const lastError = await new Promise((resolve) => contextMenus.create({ id: 'b', title: '' }, () => resolve(chrome.runtime.lastError?.message)));
    assert.equal(lastError, 'All menu items except for separators must have a title');
    contextMenus.create({ id: 'c', type: 'separator' });
    assert.deepEqual(created, [{ id: 'c', type: 'separator' }]);
  });
});

describe('alarms.create, which WebKit takes no callback in and returns nothing from', () => {
  it('returns a promise or calls the callback, as Chrome does', async () => {
    const calls: unknown[][] = [];
    const { alarms } = install({
      alarms: Object.create({
        create(...args: unknown[]) {
          if (typeof args[args.length - 1] !== 'object') throw new Error("Invalid call to alarms.create(). The 'info' value is invalid, because an object is expected.");
          calls.push(args);
        },
      }),
    });
    await new Promise((resolve) => alarms.create('a', { periodInMinutes: 1 }, resolve));
    assert.ok(alarms.create({ delayInMinutes: 1 }) instanceof Promise);
    assert.deepEqual(calls, [['a', { periodInMinutes: 1 }], [{ delayInMinutes: 1 }]]);
    assert.throws(() => alarms.create('b', () => {}), /'info' value is invalid/, 'Chrome throws without an info object too');
  });
});

describe('action calls with a null tabId', () => {
  it('reads it as no tab, as Chrome does', () => {
    const details: unknown[] = [];
    const { action } = install({
      action: Object.create({
        setIcon(value: any) {
          if (value.tabId === null) throw new Error("Invalid call to action.setIcon(). The 'details' value is invalid, because 'tabId' is expected to be a number, but null was provided.");
          details.push(value);
        },
      }),
    });
    action.setIcon({ tabId: null, path: 'a.png' });
    action.setIcon({ tabId: 3, path: 'a.png' });
    assert.deepEqual(details, [{ tabId: undefined, path: 'a.png' }, { tabId: 3, path: 'a.png' }]);
  });
});

describe('scripting.registerContentScripts without a match pattern', () => {
  const { scripting } = install({
    scripting: Object.create({
      registerContentScripts(scripts: any[]) {
        const empty = scripts.find((script) => !script.matches?.length);
        if (empty) throw new Error(`Invalid call to scripting.registerContentScripts(). The 'matches' value is invalid, because it must specify at least one match pattern for script with ID '${empty.id}'.`);
        return Promise.resolve();
      },
    }),
  });

  it('rejects with Chrome\'s error where WebKit throws', async () => {
    const empty = scripting.registerContentScripts([{ id: 'a', js: ['a.js'], matches: [] }]);
    await assert.rejects(empty, { message: "Script with ID 'a' must specify at least one match." });
    await assert.rejects(scripting.registerContentScripts([{ id: 'b', js: ['b.js'] }]), { message: "Script with ID 'b' must specify 'matches'." });
    const lastError = await new Promise((resolve) => scripting.registerContentScripts([{ id: 'c', js: ['c.js'], matches: [] }], () => resolve(chrome.runtime.lastError?.message)));
    assert.equal(lastError, "Script with ID 'c' must specify at least one match.");
  });
});

// What WebKit's executeScript does with a function: runs it in each target document, here one per tab.
function runIn(documents: Record<number, any>, injection: any) {
  (globalThis as any).document = documents[injection.target.tabId];
  try {
    return Promise.resolve(injection.func(...(injection.args ?? []))).then((result) => [{ frameId: 0, result }]);
  } finally {
    delete (globalThis as any).document;
  }
}

/** Lilo's injection that reads each target document's URL before the extension's own. */
const checksURL = (injection: any) => injection.args?.[0] === 'document' && injection.args.length === 2;

describe('scripting.executeScript, which WebKit always runs at once', () => {
  it('waits for the target documents to load unless asked to inject immediately, as Chrome', async () => {
    const injections: any[] = [];
    let readyState = 'loading';
    const loaded: Array<() => void> = [];
    const page = { URL: 'https://example.com/', get readyState() { return readyState; }, addEventListener: (_type: string, listener: () => void) => loaded.push(listener) };
    const { scripting } = install({
      runtime: { getURL: (path: string) => `chrome-extension://abc/${path}` },
      scripting: Object.create({
        async executeScript(injection: any) {
          injections.push(injection);
          return runIn({ 1: page }, injection);
        },
      }),
    });

    const results = scripting.executeScript({ target: { tabId: 1 }, func: () => readyState });
    await new Promise(setImmediate);
    assert.equal(injections.length, 1, 'only the wait for the document runs while it loads');
    readyState = 'interactive';
    loaded.forEach((listener) => listener());
    assert.deepEqual(await results, [{ frameId: 0, result: 'interactive' }]);
    assert.equal(injections[0].injectImmediately, true);

    injections.length = 0;
    readyState = 'loading';
    assert.deepEqual(await scripting.executeScript({ target: { tabId: 1 }, injectImmediately: true, func: () => 'now' }), [{ frameId: 0, result: 'now' }]);
    assert.equal(injections.length, 2, 'the URL check does not wait');
  });

  it("runs Lilo's content compat ahead of isolated-world files only", async () => {
    const injections: any[] = [];
    const { scripting } = install({
      runtime: { getURL: (path: string) => `chrome-extension://abc/${path}` },
      scripting: Object.create({
        async executeScript(injection: any) {
          if (checksURL(injection)) return [{ frameId: 0, result: 'https://example.com/' }];
          injections.push(injection);
          return [{ frameId: 0, result: 'done' }];
        },
      }),
    });
    await scripting.executeScript({ target: { tabId: 1 }, files: ['a.js', 'b.js'] });
    await scripting.executeScript({ target: { tabId: 1 }, files: ['a.js'], world: 'MAIN' });
    await scripting.executeScript({ target: { tabId: 1 }, func: () => 1 });
    assert.deepEqual(injections.map((injection) => injection.files), [['_lilo/lilo-content-compat.js', 'a.js', 'b.js'], ['a.js'], undefined]);
  });
});

describe('scripting on a tab', () => {
  const documents = {
    1: { URL: 'chrome-extension://abc/popup.html', readyState: 'complete', adoptedStyleSheets: [] },
    2: { URL: 'https://example.com/', readyState: 'complete', adoptedStyleSheets: [] as any[] },
  };

  it("refuses the extension's own pages, naming them to an extension holding tabs, as Chrome does", async () => {
    const injected: unknown[] = [];
    let tabsGranted = true;
    // Installed here: the scripting calls read the `chrome` of the context they run in.
    const { scripting } = install({
      runtime: { getURL: (path: string) => `chrome-extension://abc/${path}` },
      permissions: Object.create({ contains: async ({ permissions }: { permissions: string[] }) => tabsGranted && permissions.includes('tabs') }),
      scripting: Object.create({
        executeScript(injection: any) {
          if (!checksURL(injection)) injected.push(injection.target.tabId);
          return runIn(documents, checksURL(injection) ? injection : { ...injection, func: () => 'done' });
        },
        insertCSS(injection: any) { injected.push(injection.target.tabId); return Promise.resolve(); },
      }),
    });
    const refusal = 'Cannot access contents of url "chrome-extension://abc/popup.html". Extension manifest must request permission to access this host.';
    await assert.rejects(scripting.executeScript({ target: { tabId: 1 }, func: () => 1 }), { message: refusal });
    await assert.rejects(scripting.insertCSS({ target: { tabId: 1 }, css: 'a{}' }), { message: refusal });
    const lastError = await new Promise((resolve) => scripting.executeScript({ target: { tabId: 1 }, files: ['a.js'] }, () => resolve(chrome.runtime.lastError?.message)));
    assert.equal(lastError, refusal);
    tabsGranted = false;
    await assert.rejects(scripting.executeScript({ target: { tabId: 1 }, func: () => 1 }), {
      message: 'Cannot access contents of the page. Extension manifest must request permission to access the respective host.',
    });
    assert.deepEqual(await scripting.executeScript({ target: { tabId: 2 }, injectImmediately: true, func: () => 1 }), [{ frameId: 0, result: 'done' }]);
    assert.deepEqual(injected, [2]);
  });

  it('inserts and removes CSS in the frames named, which WebKit styles only the main frame of', async () => {
    const sheets: any[] = [];
    (globalThis as any).CSSStyleSheet = class { css = ''; replaceSync(css: string) { this.css = css; sheets.push(this); } };
    const insertedByWebKit: unknown[] = [];
    const { scripting } = install({
      runtime: { getURL: (path: string) => `chrome-extension://abc/${path}` },
      permissions: Object.create({ contains: async () => false }),
      scripting: Object.create({
        executeScript: (injection: any) => runIn(documents, injection),
        insertCSS(injection: any) { insertedByWebKit.push(injection); return Promise.resolve(); },
        removeCSS: () => Promise.resolve(),
      }),
    });
    try {
      assert.equal(await scripting.insertCSS({ target: { tabId: 2, frameIds: [0] }, css: 'a{}' }), undefined);
      assert.equal(insertedByWebKit.length, 1, 'the main frame alone is WebKit\'s');
      assert.equal(await scripting.insertCSS({ target: { tabId: 2, frameIds: [3] }, css: 'b{}' }), undefined);
      assert.deepEqual(documents[2].adoptedStyleSheets.map((sheet) => sheet.css), ['b{}']);
      await scripting.removeCSS({ target: { tabId: 2, frameIds: [3] }, css: 'b{}' });
      assert.deepEqual(documents[2].adoptedStyleSheets, []);
      await assert.rejects(scripting.insertCSS({ target: { tabId: 1, frameIds: [3] }, css: 'c{}' }), {
        message: 'Cannot access contents of the page. Extension manifest must request permission to access the respective host.',
      });
      assert.deepEqual(documents[1].adoptedStyleSheets, [], "the extension's own page keeps no style");
      assert.equal(insertedByWebKit.length, 1);
    } finally {
      delete (globalThis as any).CSSStyleSheet;
    }
  });

  it('keeps working once the extension replaces chrome with its own wrapper, as Proton Pass does', async () => {
    const { scripting } = install({
      runtime: { getURL: (path: string) => `chrome-extension://abc/${path}` },
      scripting: Object.create({ executeScript: async (injection: any) => [{ result: checksURL(injection) ? 'https://example.com/' : 'done' }] }),
    });
    const installed = (globalThis as any).chrome;
    (globalThis as any).chrome = new Proxy({}, { get: () => undefined });
    try {
      assert.deepEqual(await scripting.executeScript({ target: { tabId: 2 }, func: () => 1 }), [{ result: 'done' }]);
    } finally {
      (globalThis as any).chrome = installed;
    }
  });
});

describe('content scripts registered at run time', () => {
  it("run Lilo's content compat first outside the MAIN world, which the registrations never show", async () => {
    let registered: any[] = [];
    const { scripting } = install({
      scripting: Object.create({
        async registerContentScripts(scripts: any[]) { registered.push(...scripts.map((script) => ({ world: 'ISOLATED', ...script }))); },
        async updateContentScripts(scripts: any[]) {
          registered = registered.map((script) => ({ ...script, ...scripts.find((update) => update.id === script.id) }));
        },
        async getRegisteredContentScripts(filter?: { ids?: string[] }) {
          return registered.filter((script) => !filter?.ids || filter.ids.includes(script.id));
        },
      }),
    });
    await scripting.registerContentScripts([
      { id: 'a', js: ['a.js'], matches: ['*://*/*'] },
      { id: 'b', js: ['b.js'], matches: ['*://*/*'], world: 'MAIN' },
      { id: 'c', css: ['c.css'], matches: ['*://*/*'] },
    ]);
    const js = () => Object.fromEntries(registered.map((script) => [script.id, script.js]));
    assert.deepEqual(js(), { a: ['_lilo/lilo-content-compat.js', 'a.js'], b: ['b.js'], c: undefined });
    assert.deepEqual((await scripting.getRegisteredContentScripts()).map((script: any) => script.js), [['a.js'], ['b.js'], undefined]);

    await scripting.updateContentScripts([{ id: 'a', world: 'MAIN' }, { id: 'b', js: ['b2.js'] }]);
    assert.deepEqual(js(), { a: ['a.js'], b: ['b2.js'], c: undefined });
    await scripting.updateContentScripts([{ id: 'a', world: 'ISOLATED' }, { id: 'c', js: ['c.js'], world: 'ISOLATED' }]);
    assert.deepEqual(js(), { a: ['_lilo/lilo-content-compat.js', 'a.js'], b: ['b2.js'], c: ['_lilo/lilo-content-compat.js', 'c.js'] });
    const ids = await new Promise((resolve) => scripting.getRegisteredContentScripts({ ids: ['c'] }, (scripts: any[]) => resolve(scripts.map((script) => script.js))));
    assert.deepEqual(ids, [['c.js']]);
  });
});

describe('i18n.getMessage called on another object', () => {
  it('answers as on chrome.i18n, as Chrome does', () => {
    const i18n = Object.create({
      getMessage(this: unknown, name: string) { return this === i18n ? `message ${name}` : undefined; },
    });
    const chrome = install({ i18n });
    assert.equal(chrome.i18n.getMessage.apply(chrome, ['a']), 'message a');
    const { getMessage } = chrome.i18n;
    assert.equal(getMessage('b'), 'message b');
  });
});

describe('nativeMessaging, which Lilo grants every extension for its channel', () => {
  const removed: unknown[] = [];
  const optional = install({
    permissions: Object.create({
      contains: async () => true,
      request: async () => true,
      remove: async (request: unknown) => { removed.push(request); return true; },
      getAll: async () => ({ permissions: ['nativeMessaging', 'tabs'], origins: [] }),
    }),
  }, ['tabs'], ['nativeMessaging']).permissions;
  const required = install({
    permissions: Object.create({ contains: async () => true, getAll: async () => ({ permissions: ['nativeMessaging'], origins: [] }) }),
  }, ['nativeMessaging']).permissions;

  it('is held when the manifest requires it or the user granted it', async () => {
    held = ['tabs'];
    assert.equal(await optional.contains({ permissions: ['nativeMessaging'] }), false);
    assert.deepEqual((await optional.getAll()).permissions, ['tabs']);
    assert.equal(await required.contains({ permissions: ['nativeMessaging'] }), true);
    assert.deepEqual((await required.getAll()).permissions, ['nativeMessaging']);
    held = ['nativeMessaging', 'tabs'];
    assert.equal(await optional.contains({ permissions: ['nativeMessaging'] }), true);
    assert.deepEqual((await optional.getAll()).permissions.sort(), ['nativeMessaging', 'tabs']);
  });

  it("is granted at Lilo's prompt and removed from Lilo's grants, never from WebKit", async () => {
    liloCalls.length = 0;
    granted = false;
    assert.equal(await optional.request({ permissions: ['nativeMessaging'] }), false);
    await optional.remove({ permissions: ['nativeMessaging', 'tabs'] });
    assert.deepEqual(removed, [{ permissions: ['tabs'] }]);
    assert.deepEqual(liloCalls, [
      { method: 'request', params: { permissions: ['nativeMessaging'], origins: [] } },
      { method: 'remove', params: { permissions: ['nativeMessaging'] } },
    ]);
  });
});

describe('optional permissions WebKit does not know', () => {
  const prompted: unknown[] = [];
  const known = new Set(['tabs', 'scripting']);
  const { permissions } = install({
    permissions: Object.create({
      contains: rejectUnknown(known),
      request: (request: { permissions?: string[] }) => rejectUnknown(known)(request).then(() => { prompted.push(request); return true; }),
      getAll: async () => ({ permissions: ['tabs'], origins: [] }),
    }),
  }, ['tabs'], ['scripting', 'pageCapture']);

  it("are asked for in one prompt, Lilo's, with the rest of the request", async () => {
    liloCalls.length = 0;
    granted = true;
    assert.equal(await permissions.request({ permissions: ['scripting', 'pageCapture'], origins: ['<all_urls>'] }), true);
    assert.deepEqual(prompted, []);
    assert.deepEqual(liloCalls, [{ method: 'request', params: { permissions: ['scripting', 'pageCapture'], origins: ['<all_urls>'] } }]);
  });

  it('leave a request WebKit knows to WebKit', async () => {
    liloCalls.length = 0;
    assert.equal(await permissions.request({ permissions: ['scripting'] }), true);
    assert.deepEqual(prompted, [{ permissions: ['scripting'] }]);
    assert.deepEqual(liloCalls, []);
  });

  it('are held once granted', async () => {
    held = ['tabs'];
    assert.equal(await permissions.contains({ permissions: ['pageCapture'] }), false);
    assert.deepEqual((await permissions.getAll()).permissions, ['tabs']);
    held = ['pageCapture', 'tabs'];
    assert.equal(await permissions.contains({ permissions: ['tabs', 'pageCapture'] }), true);
    assert.deepEqual((await permissions.getAll()).permissions.sort(), ['pageCapture', 'tabs']);
  });
});

describe('permission origins WebKit rejects', () => {
  const rejectWebSockets = async (request: { origins?: string[] }) => {
    const pattern = request.origins?.find((origin) => origin.startsWith('ws'));
    if (pattern) throw new Error(`Invalid call to permissions.contains(). The 'origins' value is invalid, because '${pattern}' is not a valid pattern.`);
    return true;
  };

  it('count as held when the manifest asks for them', async () => {
    const runtime = { getManifest: () => ({ permissions: [], host_permissions: ['wss://*/*'] }) };
    (globalThis as any).chrome = { permissions: Object.create({ contains: rejectWebSockets }), runtime };
    installChromeCompat({});
    const { permissions } = (globalThis as any).chrome;
    assert.equal(await permissions.contains({ origins: ['wss://*/*', 'https://*/*'] }), true);
    assert.equal(await permissions.contains({ origins: ['ws://*/*'] }), false);
  });
});
