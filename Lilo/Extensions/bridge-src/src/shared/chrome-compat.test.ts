import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import v8 from 'node:v8';
import vm from 'node:vm';
import { closePage, installChromeCompat } from './chrome-compat.ts';
import { CHANNEL_HOST } from './ipc.ts';
import { mockGapAPI, pushGapEvent } from './ipc.testkit.ts';

// WebKit's namespace objects keep their methods on a prototype, which its `browser` alias shares;
// a Set's methods stand for WebKit's native ones, which need their object as `this`.
class Runtime extends Set<string> {
  permissions: string[];
  constructor(permissions: string[]) {
    super(['a']);
    this.permissions = permissions;
  }
  getManifest() { return { permissions: this.permissions }; }
  get lastError(): unknown { return undefined; }
}

mockGapAPI(() => null);

function install(namespaces: Record<string, unknown>, permissions: string[] = []): any {
  (globalThis as any).chrome = { runtime: new Runtime(permissions), ...namespaces };
  installChromeCompat({});
  return (globalThis as any).chrome;
}

describe('additions', () => {
  it('go on the prototype, which WebKit browser shares, never over WebKit own members', () => {
    class Windows {}
    class I18n { detectLanguage() { return 'webkit'; } }
    const chrome = install({ windows: new Windows(), i18n: new I18n() });
    assert.equal(typeof chrome.windows.onBoundsChanged.addListener, 'function');
    assert.equal(typeof (new Windows() as any).onBoundsChanged.addListener, 'function', 'browser.windows has them too');
    assert.equal(chrome.i18n.detectLanguage(), 'webkit');
  });

  it("give extension Chrome's ViewType, which its schemas no longer list", () => {
    const chrome = install({ extension: new (class {})() });
    assert.deepEqual(chrome.extension.ViewType, { TAB: 'tab', POPUP: 'popup' });
  });

  it('leave getBackgroundPage out of a worker, as Chrome, and keep it in a page', () => {
    class Extension { getBackgroundPage() { return null; } }
    assert.equal(install({ extension: new Extension() }).extension.getBackgroundPage, undefined);
    (globalThis as any).chrome = { runtime: new Runtime([]), extension: new Extension() };
    installChromeCompat({}, true);
    assert.equal((globalThis as any).chrome.extension.getBackgroundPage(), null);
  });

  it("give browser.cookies getPartitionKey, and the listeners of its onChanged to Lilo's event", () => {
    const webKitListeners: unknown[] = [];
    class Cookies { onChanged = { addListener(listener: unknown) { webKitListeners.push(listener); } }; }
    const webKit = new Cookies();
    install({ cookies: webKit }, ['cookies']);
    assert.equal(typeof (webKit as any).getPartitionKey, 'function');
    const heard: unknown[] = [];
    webKit.onChanged.addListener((info: unknown) => heard.push(info));
    pushGapEvent({ namespace: 'cookies', event: 'onChanged', args: [{ cookie: { name: 'a' }, removed: false, cause: 'explicit' }] });
    assert.deepEqual(webKitListeners, [], 'WebKit never calls it');
    return new Promise((resolve) => setTimeout(resolve, 0)).then(() => assert.equal(heard.length, 1));
  });

  it('reach a namespace object WebKit replaces later', () => {
    const raw: any = { runtime: new Runtime([]), windows: {} };
    (globalThis as any).chrome = raw;
    installChromeCompat({});
    raw.windows = {};
    assert.equal(typeof (globalThis as any).chrome.windows.onBoundsChanged.addListener, 'function');
  });

  it('stay on the namespace and event objects WebKit would recreate once collected', async () => {
    v8.setFlagsFromString('--expose-gc');
    const gc = vm.runInNewContext('gc') as () => void;
    // As WebKit's wrappers: held weakly, recreated with a new prototype once collected.
    const weakly = (create: () => object) => {
      let ref: WeakRef<object> | undefined;
      return () => ref?.deref() ?? (ref = new WeakRef(create())).deref()!;
    };
    const onMessage = weakly(() => new (class { addListener() {} })());
    const browser: any = { runtime: new Runtime([]) };
    Object.defineProperty(browser, 'windows', { enumerable: true, get: weakly(() => new (class {})()) });
    Object.defineProperty(browser, 'alarms', { enumerable: true, get: weakly(() => Object.defineProperty(new (class {})(), 'onAlarm', { enumerable: true, get: onMessage })) });
    (globalThis as any).browser = browser;
    (globalThis as any).chrome = browser;
    installChromeCompat({});
    await new Promise((resolve) => setTimeout(resolve, 0));
    gc();
    assert.equal(typeof browser.windows.onBoundsChanged?.addListener, 'function');
    assert.equal(typeof browser.alarms.onAlarm.hasListeners, 'function');
    delete (globalThis as any).browser;
  });

  it("leave browser WebKit's, through which it finds the context's listeners, when the extension assigns it", () => {
    const browser = { runtime: new Runtime([]) };
    (globalThis as any).browser = browser;
    const chrome = install({});
    (globalThis as any).browser = chrome;
    assert.equal((globalThis as any).browser, browser);
    delete (globalThis as any).browser;
  });

  it('replace WebKit badge colors with the action surface Lilo bridges', () => {
    class Action { setBadgeBackgroundColor() { return 'webkit'; } }
    (globalThis as any).chrome = { runtime: new Runtime([]), action: new Action() };
    installChromeCompat({ setBadgeBackgroundColor: () => 'lilo' });
    assert.equal((globalThis as any).chrome.action.setBadgeBackgroundColor(), 'lilo');
    assert.equal(typeof (globalThis as any).chrome.action.onUserSettingsChanged.addListener, 'function');
  });
});

describe('runtime.onInstalled and onStartup', () => {
  it('give their listeners to the events Lilo pushes, for chrome and browser alike', () => {
    class NativeEvent {
      listeners = new Set<unknown>();
      addListener(listener: unknown) { this.listeners.add(listener); }
      removeListener(listener: unknown) { this.listeners.delete(listener); }
      hasListener(listener: unknown) { return this.listeners.has(listener); }
    }
    const runtime: any = Object.assign(new Runtime([]), { onInstalled: new NativeEvent(), onStartup: new NativeEvent() });
    (globalThis as any).chrome = { runtime };
    installChromeCompat({});
    const heard: unknown[] = [];
    const listener = (details: unknown) => heard.push(details);

    runtime.onInstalled.addListener(listener);
    pushGapEvent({ namespace: 'runtime', event: 'onInstalled', args: [{ reason: 'install' }] });

    assert.deepEqual(heard, [{ reason: 'install' }]);
    assert.equal(runtime.onInstalled.listeners.size, 0, 'WebKit never calls it');
    assert.equal((globalThis as any).chrome.runtime.onInstalled.hasListener(listener), true);
    runtime.onInstalled.removeListener(listener);
    assert.equal(runtime.onInstalled.hasListener(listener), false);
  });
});

describe('runtime.getManifest', () => {
  it("names the extension's own worker, which WebKit runs through Lilo's wrapper, for chrome and browser alike", () => {
    class WorkerRuntime extends Runtime {
      getManifest() {
        return { permissions: [], background: { service_worker: 'js/lilo-background-wrapper.js', lilo_service_worker: 'js/sw.js', type: 'module' } };
      }
    }
    const runtime = new WorkerRuntime([]);
    (globalThis as any).chrome = { runtime };
    installChromeCompat({});
    assert.deepEqual((globalThis as any).chrome.runtime.getManifest().background, { service_worker: 'js/sw.js', type: 'module' });
    assert.deepEqual(runtime.getManifest().background, { service_worker: 'js/sw.js', type: 'module' });
  });
});

describe('members', () => {
  it('are own and enumerable, and work detached, as in Chrome', () => {
    // As WebKit's, the storage area prototype has no constructor.
    const local = Object.assign(Object.create({ get(this: any, key: string) { return this.values[key]; } }), { values: { a: 1 } });
    class Storage { local = local; onChanged = { addListener() {} }; }
    const chrome = install({ storage: new Storage() });
    const { getManifest } = chrome.runtime;
    assert.deepEqual(getManifest(), { permissions: [] });
    const own = (o: object) => Object.keys(o).filter((key) => typeof (o as any)[key] === 'function');
    assert.deepEqual(own(chrome.storage.local), ['get']);
    const get = chrome.storage.local.get;
    assert.equal(get('a'), 1);
    assert.equal(chrome.runtime.getManifest, chrome.runtime.getManifest);
  });

  it('include the events and objects WebKit keeps out of a copy, as in Chrome', () => {
    // As WebKit's, its events are own properties that are not enumerable and cannot be redefined.
    class Alarms { get() { return this; } }
    const webKit: Alarms & { onAlarm?: unknown } = Object.defineProperty(new Alarms(), 'onAlarm', { value: { addListener() {} } });
    const chrome = install({ alarms: webKit });
    const copy = { ...chrome.alarms };
    assert.deepEqual(Object.keys(copy).sort(), ['get', 'onAlarm']);
    assert.equal(copy.onAlarm, webKit.onAlarm);
    assert.equal(copy.get(), webKit);
  });

  it("keep WebKit's unpatched method callable on what chrome hands out", () => {
    // As WebKit's native methods, which answer nothing on another object.
    class Alarms { create() { return Object.getPrototypeOf(this) === Alarms.prototype ? 'created' : undefined; } }
    const chrome = install({ alarms: new Alarms() });
    assert.equal(chrome.alarms.create.__liloUnwrapped.call(chrome.alarms), 'created');
  });
});

describe('namespaces', () => {
  it('can be replaced, as in Chrome, and come back untouched', () => {
    const raw: any = { runtime: new Runtime([]) };
    Object.defineProperty(raw, 'contextMenus', { value: {}, writable: false, configurable: true });
    (globalThis as any).chrome = raw;
    installChromeCompat({});
    class Mine { create() { return 'mine'; } }
    const mine = new Mine();
    (globalThis as any).chrome.contextMenus = mine;
    assert.equal((globalThis as any).chrome.contextMenus, mine);
    assert.equal(Object.hasOwn(mine, 'create'), false, 'Lilo leaves it as it is');
  });
});

describe('constants', () => {
  it('fill what WebKit lacks, the hand-written ones over the generated ones', () => {
    class Dnr { MAX_NUMBER_OF_REGEX_RULES = 7; }
    const chrome = install({ declarativeNetRequest: new Dnr(), tabs: {}, system: { display: {} } });
    assert.equal(chrome.declarativeNetRequest.MAX_NUMBER_OF_REGEX_RULES, 7);
    assert.equal(chrome.declarativeNetRequest.MAX_NUMBER_OF_SESSION_RULES, 30000);
    assert.equal(chrome.declarativeNetRequest.ResourceType.MAIN_FRAME, 'main_frame');
    assert.equal(chrome.tabs.TabStatus.COMPLETE, 'complete');
    assert.equal(chrome.tabs.TAB_ID_NONE, -1);
    assert.equal(chrome.system.display.MirrorMode.OFF, 'off');
    assert.equal(chrome.runtime.PlatformOs.MAC, 'mac');
  });

  it('reach the namespaces present at startup, for browser', () => {
    class Scripting {}
    const raw: any = { runtime: new Runtime([]), scripting: new Scripting() };
    (globalThis as any).chrome = raw;
    installChromeCompat({});
    assert.equal((new Scripting() as any).ExecutionWorld.MAIN, 'MAIN');
  });
});

describe("WebKit's errors", () => {
  class FailingRuntime extends Runtime {
    error: { message: string } | null = null;
    get lastError(): unknown { return this.error; }
    getURL(path: string) { return `chrome-extension://own/${path}`; }
  }
  const runtime = new FailingRuntime([]);
  const notFound = (method: string) => `Invalid call to ${method}(). Tab not found.`;
  // WebKit's runtime.lastError holds only while its callback runs.
  const fail = (method: string, callback?: () => void) => {
    if (!callback) return Promise.reject(new Error(notFound(method)));
    runtime.error = { message: notFound(method) };
    try { callback(); } finally { runtime.error = null; }
    return undefined;
  };
  class Tabs {
    get(_tabId: number, callback?: () => void) { return fail('tabs.get', callback); }
    sendMessage(_tabId: number, _message: unknown, callback?: () => void) { return fail('tabs.sendMessage', callback); }
    remove(tabIds: number[]) { return Promise.reject(new Error(`Invalid call to tabs.remove(). Tab '${tabIds[0]}' was not found.`)); }
  }
  class Action { setBadgeText(_details: object, callback?: () => void) { return fail('action.setBadgeText', callback); } }
  class Scripting { executeScript() { return Promise.reject(new Error('Invalid call to scripting.executeScript(). This extension does not have access to this tab.')); } }

  function chrome(): any {
    (globalThis as any).chrome = { runtime, tabs: new Tabs(), action: new Action(), scripting: new Scripting() };
    installChromeCompat({});
    return (globalThis as any).chrome;
  }

  it("read in Chrome's words, as lastError and as the rejection", async () => {
    const api = chrome();
    const read = (call: (callback: () => void) => void) => new Promise((resolve) => call(() => resolve(api.runtime.lastError?.message)));
    assert.equal(await read((callback) => api.tabs.get(7, callback)), 'No tab with id: 7.');
    await assert.rejects(api.tabs.get(7), { message: 'No tab with id: 7.' });
    await assert.rejects(api.action.setBadgeText({ tabId: 8, text: 'a' }), { message: 'No tab with id: 8.' });
    await assert.rejects(api.tabs.remove([10, 11]), { message: 'No tab with id: 10.' });
    await assert.rejects(api.scripting.executeScript({ target: { tabId: 1 }, func: () => {} }), { message: /^Cannot access contents of the page\./ });
    await assert.rejects(api.tabs.sendMessage(9, 'hi'), { message: 'Could not establish connection. Receiving end does not exist.' });
    assert.equal(await read((callback) => api.tabs.sendMessage(9, 'hi', callback)), 'Could not establish connection. Receiving end does not exist.');
  });

  it("settle never a closed tab's page message, as Chrome runs nothing more of a closed page", async () => {
    const closed = 'Invalid call to runtime.sendMessage(). Tab not found.';
    class ClosingRuntime extends FailingRuntime {
      sendMessage(_message: unknown, callback?: () => void) {
        if (!callback) return Promise.reject(new Error(closed));
        this.error = { message: closed };
        try { callback(); } finally { this.error = null; }
        return undefined;
      }
    }
    (globalThis as any).chrome = { runtime: new ClosingRuntime([]) };
    installChromeCompat({}, true);
    const api = (globalThis as any).chrome;
    let settled = false;
    api.runtime.sendMessage('hi', () => { settled = true; });
    api.runtime.sendMessage('hi').then(() => { settled = true; }, () => { settled = true; });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(settled, false);
  });

  it('log no unchecked lastError a callback may have read through browser', () => {
    const api = chrome();
    const logged: unknown[] = [];
    const { error } = console;
    console.error = (...args: unknown[]) => { logged.push(args[0]); };
    try {
      // `browser.runtime` is WebKit's own, whose lastError Lilo cannot see being read.
      api.tabs.get(7, () => runtime.lastError);
    } finally {
      console.error = error;
    }
    assert.deepEqual(logged, []);
  });
});

describe('the view chrome hands out for WebKit own properties', () => {
  it('reads lastError undefined, not null, without an error', () => {
    class NullLastError extends Runtime { get lastError(): unknown { return null; } }
    (globalThis as any).chrome = { runtime: new NullLastError([]) };
    installChromeCompat({});
    assert.equal((globalThis as any).chrome.runtime.lastError, undefined);
  });

  function nativeRuntime() {
    const opened: string[] = [];
    const runtime: any = new Runtime(['nativeMessaging']);
    const disconnects: Array<() => void> = [];
    const messages: Array<(message: unknown) => void> = [];
    runtime.connectNative = (application: string) => {
      opened.push(application);
      return {
        name: application,
        onMessage: { addListener: (listener: (message: unknown) => void) => messages.push(listener) },
        onDisconnect: { addListener: (listener: () => void) => disconnects.push(listener) },
        postMessage() {},
        disconnect() {},
      };
    };
    (globalThis as any).chrome = { runtime };
    installChromeCompat({});
    return { chrome: (globalThis as any).chrome, runtime, opened, disconnects, messages };
  }

  it('passes Lilo channel straight through and marks the other hosts', () => {
    const { chrome, opened } = nativeRuntime();
    chrome.runtime.connectNative(CHANNEL_HOST);
    chrome.runtime.connectNative('com.example.host');
    assert.deepEqual(opened, [CHANNEL_HOST, 'com.example.host?lilo']);
  });

  it('reports the port error as lastError while onDisconnect listeners run', () => {
    const { chrome, disconnects, messages } = nativeRuntime();
    const port = chrome.runtime.connectNative('com.example.host');
    let seen: unknown;
    port.onDisconnect.addListener(() => { seen = chrome.runtime.lastError; });
    messages[0]({ liloNativePortError: 'Specified native messaging host not found.' });
    disconnects[0]();
    assert.deepEqual(seen, { message: 'Specified native messaging host not found.' });
    assert.equal(chrome.runtime.lastError, undefined);
  });

  it('throws Chrome\'s error on a post once the port is disconnected', () => {
    const { chrome, disconnects } = nativeRuntime();
    const port = chrome.runtime.connectNative('com.example.host');
    port.postMessage('before');
    disconnects[0]();
    assert.throws(() => port.postMessage('after'), { message: 'Attempting to use a disconnected port object' });
    const local = chrome.runtime.connectNative('com.example.host');
    local.disconnect();
    assert.throws(() => local.postMessage('after'), { message: 'Attempting to use a disconnected port object' });
  });

  it('binds WebKit native methods once and keeps the others as they are', () => {
    const { chrome } = nativeRuntime();
    assert.equal(chrome.runtime.has('a'), true);
    assert.equal(chrome.runtime.has, chrome.runtime.has);
    const replaced = () => false;
    chrome.runtime.has = replaced;
    assert.equal(chrome.runtime.has, replaced, 'an extension that replaces a method reads its own');
  });
});

describe('a page after its window.close()', () => {
  // As WebKit's: callbacks and promises settle a few ms later, events keep their listeners on a prototype.
  class Event {
    listeners = new Set<(...args: unknown[]) => void>();
    addListener(listener: (...args: unknown[]) => void) { this.listeners.add(listener); }
    removeListener(listener: (...args: unknown[]) => void) { this.listeners.delete(listener); }
    hasListener(listener: (...args: unknown[]) => void) { return this.listeners.has(listener); }
    dispatch(...args: unknown[]) { this.listeners.forEach((listener) => listener(...args)); }
  }
  // WebKit's sub-namespaces have a prototype without a constructor.
  const area = {
    get(keys: unknown, callback?: (items: object) => void) {
      const answer = new Promise<object>((resolve) => setTimeout(() => resolve({ keys }), 5));
      if (!callback) return answer;
      answer.then(callback);
      return undefined;
    },
  };
  class Storage { local = Object.create(area); onChanged = new Event(); }

  function page(): any {
    (globalThis as any).chrome = { runtime: new Runtime(['storage']), storage: new Storage() };
    installChromeCompat({}, true);
    return (globalThis as any).chrome;
  }

  it('runs no API callback, promise or event listener', async () => {
    const chrome = page();
    const ran: string[] = [];
    chrome.storage.onChanged.addListener(() => ran.push('listener'));
    chrome.storage.local.get('a', () => ran.push('callback'));
    chrome.storage.local.get('a').then(() => ran.push('promise'));
    closePage();
    chrome.storage.onChanged.addListener(() => ran.push('listener added after'));
    chrome.storage.onChanged.dispatch({});
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(ran, []);
  });

  it('still answers before it', async () => {
    const chrome = page();
    const items = await new Promise((resolve) => chrome.storage.local.get('a', resolve));
    assert.deepEqual(items, { keys: 'a' });
    assert.deepEqual(await chrome.storage.local.get('b'), { keys: 'b' });
  });
});
