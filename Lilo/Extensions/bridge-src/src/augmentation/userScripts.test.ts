import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  // Listener reports are covered by gap-event.test.ts.
  if (msg.namespace === 'events') return Promise.resolve();
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(nextResult)));
});

(globalThis as any).chrome = {
  runtime: {},
  windows: { getAll: async () => [{ id: 10 }, { id: 20 }] },
  tabs: { query: async ({ windowId }: { windowId: number }) => [{ id: windowId + 1, index: 0 }, { id: windowId + 2, index: 1 }] },
};

const { userScriptsAugmentation, onUserScriptMessage } = await import('./userScripts.ts');

const settle = () => new Promise((resolve) => setImmediate(resolve));

describe('userScriptsAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = undefined;
  });

  it('register sends the scripts and resolves undefined', async () => {
    const scripts = [{ id: 'a', matches: ['*://*/*'], js: [{ code: '1' }] }];

    const result = await userScriptsAugmentation.register(scripts);

    assert.equal(result, undefined);
    assert.deepEqual(gapCalls[0], { namespace: 'userScripts', method: 'register', params: { scripts } });
  });

  it('getScripts accepts a lone callback', async () => {
    nextResult = [{ id: 'a' }];

    const scripts = await new Promise((resolve) => userScriptsAugmentation.getScripts(resolve));

    assert.deepEqual(scripts, [{ id: 'a' }]);
    assert.deepEqual(gapCalls[0].params, { filter: undefined });
  });
});

describe('runtime.onUserScriptMessage', () => {
  beforeEach(() => {
    gapCalls.length = 0;
  });

  it('replies with what the listener sends, with the sender tab resolved', async () => {
    let seenSender: any;
    const listener = (message: any, sender: any, sendResponse: (r: unknown) => void) => {
      seenSender = sender;
      sendResponse({ echo: message });
    };
    onUserScriptMessage.addListener(listener);

    onUserScriptMessage.dispatch('hi', { id: 'ext', tabPosition: { windowPosition: 1, index: 1 } }, 'r1');
    await settle();
    await settle();
    onUserScriptMessage.removeListener(listener);

    assert.deepEqual(seenSender, { id: 'ext', tab: { id: 22, index: 1 } });
    assert.deepEqual(gapCalls, [{ namespace: 'userScripts', method: 'reply', params: { replyId: 'r1', response: { echo: 'hi' } } }]);
  });

  it('stays silent without listeners so another context can answer', async () => {
    onUserScriptMessage.dispatch('hi', { id: 'ext' }, 'r2');
    await settle();

    assert.equal(gapCalls.length, 0);
  });

  it('replies undefined once listeners return without keeping the channel open', async () => {
    const listener = () => {};
    onUserScriptMessage.addListener(listener);

    onUserScriptMessage.dispatch('hi', { id: 'ext' }, 'r3');
    await settle();
    onUserScriptMessage.removeListener(listener);

    assert.deepEqual(gapCalls[0].params, { replyId: 'r3', response: undefined });
  });
});

describe('userScripts.execute', () => {
  beforeEach(() => {
    gapCalls.length = 0;
  });

  it('sends the injection with the target tab position', async () => {
    (globalThis as any).chrome.tabs.get = async (id: number) => ({ id, index: 1, windowId: 20 });
    nextResult = [{ frameId: 0, result: 42 }];
    const injection = { target: { tabId: 22 }, js: [{ code: '6 * 7' }] };

    const results = await userScriptsAugmentation.execute(injection);

    assert.deepEqual(results, [{ frameId: 0, result: 42 }]);
    assert.deepEqual(gapCalls[0], {
      namespace: 'userScripts',
      method: 'execute',
      params: { injection, tabs: [{ windowPosition: 1, index: 1 }] },
    });
  });
});

describe('runtime.onUserScriptConnect', () => {
  beforeEach(() => {
    gapCalls.length = 0;
  });

  it('hands listeners a port that relays messages both ways until it disconnects', async () => {
    const { onUserScriptConnect } = await import('./userScripts.ts');
    const ports: any[] = [];
    const received: unknown[] = [];
    let disconnected = false;
    onUserScriptConnect.addListener((port: any) => {
      ports.push(port);
      port.onMessage.addListener((message: unknown) => received.push(message));
      port.onDisconnect.addListener(() => { disconnected = true; });
    });

    onUserScriptConnect.dispatch('connect', 'p1', 'chat', { id: 'ext', tabPosition: { windowPosition: 0, index: 0 } });
    await settle();
    await settle();
    const port = ports[0];
    assert.equal(port.name, 'chat');
    assert.equal(port.sender.tab.id, 11);

    onUserScriptConnect.dispatch('message', 'p1', { hello: true });
    port.postMessage('back');
    onUserScriptConnect.dispatch('disconnect', 'p1');

    assert.deepEqual(received, [{ hello: true }]);
    assert.deepEqual(gapCalls[0], { namespace: 'userScripts', method: 'portPost', params: { portId: 'p1', message: 'back' } });
    assert.equal(disconnected, true);
    assert.throws(() => port.postMessage('late'));
  });

  it('relays, in order, a message and a disconnect that arrive while the sender tab resolves', async () => {
    const { onUserScriptConnect } = await import('./userScripts.ts');
    const heard: string[] = [];
    const listener = (port: any) => {
      heard.push(`connect ${port.sender.tab?.id}`);
      port.onMessage.addListener((message: unknown) => heard.push(`message ${message}`));
      port.onDisconnect.addListener(() => heard.push('disconnect'));
    };
    onUserScriptConnect.addListener(listener);

    onUserScriptConnect.dispatch('connect', 'p2', 'chat', { id: 'ext', tabPosition: { windowPosition: 1, index: 0 } });
    onUserScriptConnect.dispatch('message', 'p2', 'early');
    onUserScriptConnect.dispatch('disconnect', 'p2');
    await settle();
    await settle();
    onUserScriptConnect.removeListener(listener);

    assert.deepEqual(heard, ['connect 21', 'message early', 'disconnect']);
  });
});

describe('userScripts while the switch is off', () => {
  it('leaves chrome.userScripts undefined, as Chrome does', async () => {
    const { installGapAPIs } = await import('../shared/install-gap-apis.ts');
    const installed = (allowed: boolean | undefined) => {
      (globalThis as any).__liloUserScriptsAllowed = allowed;
      const c: any = { runtime: { getManifest: () => ({ permissions: ['userScripts'] }) } };
      installGapAPIs(c);
      return c.userScripts;
    };
    try {
      assert.equal(installed(false), undefined);
      assert.equal(installed(true), userScriptsAugmentation);
      assert.equal(installed(undefined), userScriptsAugmentation);
    } finally {
      delete (globalThis as any).__liloUserScriptsAllowed;
    }
  });

  it('throws at once in a context that got the namespace before', () => {
    (globalThis as any).__liloUserScriptsAllowed = false;
    try {
      assert.throws(() => userScriptsAugmentation.getScripts(), /Allow user scripts/);
    } finally {
      delete (globalThis as any).__liloUserScriptsAllowed;
    }
  });
});

describe('userScripts in an extension page', () => {
  it('throws at once unless the profile lists this extension as allowed', () => {
    const g = globalThis as any;
    g.chrome.runtime.id = 'ext';
    g.__liloUserScriptsAllowedIds = ['other'];
    try {
      assert.throws(() => userScriptsAugmentation.getScripts(), /Allow user scripts/);
      g.__liloUserScriptsAllowedIds = ['ext'];
      assert.doesNotThrow(() => userScriptsAugmentation.getScripts());
    } finally {
      delete g.__liloUserScriptsAllowedIds;
      delete g.chrome.runtime.id;
    }
  });
});

describe('runtime user-script events while the switch is off', () => {
  it('stay, as in Chrome, where Tampermonkey requires them', async () => {
    const { installGapAPIs } = await import('../shared/install-gap-apis.ts');
    const { installChromeCompat } = await import('../shared/chrome-compat.ts');
    const g = globalThis as any;
    g.__liloUserScriptsAllowed = false;
    try {
      g.chrome = { runtime: { getManifest: () => ({ permissions: ['userScripts'] }) } };
      installGapAPIs(g.chrome);
      installChromeCompat({});
      assert.equal(g.chrome.userScripts, undefined);
      assert.equal(typeof g.chrome.runtime.onUserScriptMessage?.addListener, 'function');
      assert.equal(typeof g.chrome.runtime.onUserScriptConnect?.addListener, 'function');
    } finally {
      delete g.__liloUserScriptsAllowed;
    }
  });

  it('stay with the permission only optional, as in Chrome, where Table Capture listens before asking for it', async () => {
    const { installChromeCompat } = await import('../shared/chrome-compat.ts');
    const g = globalThis as any;
    g.chrome = { runtime: { getManifest: () => ({ permissions: [], optional_permissions: ['userScripts'] }) } };
    installChromeCompat({});
    assert.equal(typeof g.chrome.runtime.onUserScriptMessage?.addListener, 'function');
  });
});
