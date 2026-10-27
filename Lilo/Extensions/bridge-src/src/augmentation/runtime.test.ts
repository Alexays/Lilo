import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { closeGapChannel, mockGapAPI, pushGapEvent } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params?: any }> = [];
let nextResult: unknown;
/** Native's answer to the next calls; nextResult when unset. */
let answer: ((msg: any) => unknown) | undefined;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return answer ? answer(msg) : Promise.resolve(nextResult);
});
(globalThis as any).chrome = { runtime: {} };

const { runtimeAdditions, crossExtensionMessaging, crossExtensionPatches, externalEvents, onConnect, relayForContentScripts, tabsConnect } = await import('./runtime.ts');
const { liloLastError } = await import('../shared/callbackify.ts');
const { frameMark } = await import('../shared/message-answers.ts');

describe('runtime.requestUpdateCheck', () => {
  it('resolves the promise with native status and version', async () => {
    nextResult = { status: 'update_available', version: '2.0' };

    assert.deepEqual(await runtimeAdditions.requestUpdateCheck(), { status: 'update_available', version: '2.0' });
    assert.deepEqual(gapCalls.at(-1), { namespace: 'runtime', method: 'requestUpdateCheck', params: {} });
  });

  it('splits the result into (status, details) for a callback, as Chrome does', async () => {
    nextResult = { status: 'no_update', version: '' };

    const args = await new Promise<unknown[]>((resolve) => runtimeAdditions.requestUpdateCheck((...received) => resolve(received)));

    assert.deepEqual(args, ['no_update', { version: '' }]);
  });
});

describe('runtime kiosk-only calls', () => {
  it('rejects restartAfterDelay with Chrome error outside kiosk mode', async () => {
    await assert.rejects(runtimeAdditions.restartAfterDelay(10) as Promise<void>, { message: 'API available only for ChromeOS kiosk mode.' });
  });

  it('reports restart through an unchecked lastError', () => {
    const logged: unknown[] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => logged.push(...args);
    try {
      assert.equal(runtimeAdditions.restart(), undefined);
    } finally {
      console.error = original;
    }
    assert.deepEqual(logged, ['Unchecked runtime.lastError: Function available only for ChromeOS kiosk mode.']);
  });
});

describe('runtime events', () => {
  it('delivers onExtensionLoaded details native pushes', () => {
    const heard: unknown[] = [];
    runtimeAdditions.onExtensionLoaded.addListener((details) => heard.push(details));

    runtimeAdditions.onExtensionLoaded.dispatch({ reason: 'update', previousVersion: '1.0' });

    assert.deepEqual(heard, [{ reason: 'update', previousVersion: '1.0' }]);
  });
});

describe('runtime messaging to another extension', () => {
  const other = 'abcdefghijklmnopabcdefghijklmnop';
  const noReceiver = 'Could not establish connection. Receiving end does not exist.';
  const webKitCalls: unknown[][] = [];
  const webKit = {
    id: 'ponmlkjihgfedcbaponmlkjihgfedcba',
    lastError: undefined,
    connect: (...args: unknown[]) => { webKitCalls.push(['connect', ...args]); return 'webkit port'; },
    sendMessage: (...args: unknown[]) => { webKitCalls.push(['sendMessage', ...args]); return 'webkit'; },
  };
  const runtime: any = crossExtensionMessaging(webKit);
  const unreachable = () => Promise.reject(new Error(noReceiver));

  it('rejects a promise and gives a callback lastError when native reaches no listener', async () => {
    answer = unreachable;
    await assert.rejects(runtime.sendMessage(other, { a: 1 }), { message: noReceiver });
    const lastError = await new Promise((resolve) => runtime.sendMessage(other, 1, {}, () => resolve(liloLastError())));
    answer = undefined;
    assert.deepEqual(lastError, { message: noReceiver });
    assert.equal(liloLastError(), undefined);
  });

  it("sends the message to native and hands back the other extension's answer", async () => {
    answer = () => ({ response: 'pong' });
    const response = await runtime.sendMessage(other, { ping: 1 });
    const viaCallback = await new Promise((resolve) => runtime.sendMessage(other, 'again', resolve));
    answer = undefined;

    assert.equal(response, 'pong');
    assert.equal(viaCallback, 'pong');
    assert.deepEqual(gapCalls.at(-2), { namespace: 'runtime', method: 'sendExternal', params: { id: other, message: { ping: 1 } } });
  });

  it('resolves undefined, or gives a callback lastError, when the other extension does not answer', async () => {
    answer = () => ({ closed: true });
    const response = await runtime.sendMessage(other, 1);
    const lastError = await new Promise((resolve) => runtime.sendMessage(other, 1, () => resolve(liloLastError())));
    answer = undefined;

    assert.equal(response, undefined);
    assert.deepEqual(lastError, { message: 'The message port closed before a response was received.' });
  });

  it('disconnects a port with lastError set while onDisconnect listeners run', async () => {
    answer = unreachable;
    const port = runtime.connect(other, { name: 'proxy' });
    assert.equal(port.name, 'proxy');
    const lastError = await new Promise((resolve) => port.onDisconnect.addListener(() => resolve(liloLastError())));
    answer = undefined;
    assert.deepEqual(lastError, { message: noReceiver });
  });

  it('relays a port: messages in order once it connects, and the other end disconnecting', async () => {
    answer = (msg) => (msg.method === 'connectExternal' ? '9' : null);
    const port = runtime.connect(other, { name: 'vpn' });
    port.postMessage('first');
    port.postMessage('second');
    const heard: unknown[] = [];
    port.onMessage.addListener((message: unknown, from: unknown) => { assert.equal(from, port); heard.push(message); });
    const disconnected = new Promise((resolve) => port.onDisconnect.addListener(resolve));
    await new Promise((resolve) => setTimeout(resolve, 0));

    pushGapEvent({ namespace: 'runtime', event: 'portMessages', args: ['9', JSON.stringify([{ state: 'on' }])] });
    pushGapEvent({ namespace: 'runtime', event: 'portDisconnect', args: ['9'] });
    answer = undefined;
    await new Promise((resolve) => setTimeout(resolve, 10));

    assert.deepEqual(gapCalls.filter((c) => c.method === 'portPost').map((c) => c.params), [{ portId: '9', json: '["first","second"]' }], 'what one turn posts goes in one call, as JSON');
    assert.deepEqual(heard, [{ state: 'on' }]);
    assert.equal(await disconnected, port);
    assert.throws(() => port.postMessage('late'), { message: 'Attempting to use a disconnected port object' });
  });

  it('disconnects a port the other extension declined with lastError set', async () => {
    answer = (msg) => (msg.method === 'connectExternal' ? '10' : null);
    const port = runtime.connect(other);
    const lastError = new Promise((resolve) => port.onDisconnect.addListener(() => resolve(liloLastError())));
    await new Promise((resolve) => setTimeout(resolve, 0));
    pushGapEvent({ namespace: 'runtime', event: 'portDisconnect', args: ['10', noReceiver] });
    answer = undefined;

    assert.deepEqual(await lastError, { message: noReceiver });
  });

  it("leaves the extension's own messages to WebKit", () => {
    webKitCalls.length = 0;
    assert.equal(runtime.sendMessage('a message'), 'webkit');
    assert.equal(runtime.sendMessage(other, () => {}), 'webkit');
    assert.equal(runtime.sendMessage(webKit.id, 1), 'webkit');
    assert.equal(webKitCalls.length, 3);
  });
});

describe('runtime messages and ports from another extension', () => {
  /** WebKit's onMessageExternal or onConnectExternal, which web pages reach. */
  const webKitEvent = () => Object.create({ addListener(this: any, listener: any) { this.listener = listener; }, removeListener() {} });
  const webKit = { onMessageExternal: webKitEvent(), onConnectExternal: webKitEvent() };
  const events = externalEvents(() => webKit);
  const sender = { id: 'abcdefghijklmnopabcdefghijklmnop', url: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html' };

  it("answers native with a listener's response, and the web page's messages stay WebKit's", async () => {
    const listener = (message: unknown, from: unknown, sendResponse: unknown) => {
      assert.deepEqual(from, sender);
      (sendResponse as (response: unknown) => void)({ echo: message });
    };
    events.onMessageExternal.addListener(listener);
    events.onMessageExternal.dispatch('hi', sender, '4');
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(gapCalls.filter((c) => c.method === 'answerExternal').at(-1)?.params, { messageId: '4', response: { echo: 'hi' } });
    assert.equal(webKit.onMessageExternal.listener, listener);
    events.onMessageExternal.removeListener(listener);
  });

  it('tells native when a page listener does not answer', async () => {
    const listener = () => undefined;
    events.onMessageExternal.addListener(listener);
    events.onMessageExternal.dispatch('hi', sender, '5');
    await new Promise((resolve) => setTimeout(resolve, 0));
    events.onMessageExternal.removeListener(listener);

    assert.deepEqual(gapCalls.filter((c) => c.method === 'answerExternal').at(-1)?.params, { messageId: '5', worker: false });
  });

  it('hands a connecting extension a port that posts and disconnects through native', async () => {
    let received: any;
    events.onConnectExternal.addListener((port: any) => { received = port; });
    events.onConnectExternal.dispatch({ portId: '12', name: 'tunnel', sender });
    received.postMessage('ready');
    received.disconnect();
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.equal(received.name, 'tunnel');
    assert.deepEqual(received.sender, sender);
    assert.deepEqual(gapCalls.slice(-3).map((c) => [c.method, c.params]), [
      ['portAccept', { portId: '12' }], ['portPost', { portId: '12', json: '["ready"]' }], ['portDisconnect', { portId: '12' }],
    ], 'a page tells native it holds the port, which goes with the page');
  });

  it('declines a port no listener takes', async () => {
    const webKitOnly = externalEvents(() => ({ onMessageExternal: webKitEvent(), onConnectExternal: webKitEvent() }));
    webKitOnly.onConnectExternal.dispatch({ portId: '13', name: 'tunnel', sender });
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(gapCalls.at(-1), { namespace: 'runtime', method: 'portDecline', params: { portId: '13' } });
  });
});

describe('browser.runtime messaging to another extension', () => {
  const other = 'abcdefghijklmnopabcdefghijklmnop';
  const webKit = { id: 'ponmlkjihgfedcbaponmlkjihgfedcba' };
  const own = (...args: unknown[]) => ['webkit', ...args];

  it("goes through Lilo's relay, and the extension's own through WebKit", async () => {
    const sendMessage = crossExtensionPatches.sendMessage(own, () => webKit);
    const connect = crossExtensionPatches.connect(own, () => webKit);
    answer = (msg) => (msg.method === 'sendExternal' ? { response: 'pong' } : '3');
    const response = await sendMessage.call(webKit, other, 'ping');
    const port = connect.call(webKit, other, { name: 'vpn' });
    await new Promise((resolve) => setTimeout(resolve, 0));
    answer = undefined;

    assert.equal(response, 'pong');
    assert.equal(port.name, 'vpn');
    assert.deepEqual(gapCalls.at(-1), { namespace: 'runtime', method: 'connectExternal', params: { id: other, name: 'vpn' } });
    assert.deepEqual(sendMessage.call(webKit, 'hi'), ['webkit', 'hi']);
    assert.deepEqual(connect.call(webKit, { name: 'own' }), ['webkit', { name: 'own' }], "a content script's port stays WebKit's");
  });

  it("connects a page or the worker to the extension's other contexts through Lilo, as chrome.runtime.connect", async () => {
    const page = { ...webKit, connectNative() {} };
    const connect = crossExtensionPatches.connect(own, () => page);
    const from = gapCalls.length;
    const port = connect.call(page, { name: 'state' });
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(port.name, 'state');
    assert.deepEqual(gapCalls.slice(from).filter((c) => c.namespace === 'runtime').map((c) => [c.method, c.params.name]), [['connect', 'state']]);
  });
});

describe("the worker's relay of its content scripts' messages to another extension", () => {
  const other = 'abcdefghijklmnopabcdefghijklmnop';
  let relay: (...args: any[]) => unknown = () => undefined;
  relayForContentScripts({ onMessage: Object.create({ addListener(listener: (...args: any[]) => unknown) { relay = listener; } }) });
  const sender = { url: 'https://example.com/a', origin: 'https://example.com', tab: { id: 3 }, frameId: 2 };

  it("sends a message with the content script's frame as its sender, and answers with native's word", async () => {
    answer = (msg) => (msg.method === 'sendExternal' ? { response: 'pong' } : null);
    let waits: unknown;
    const relayed = await new Promise((resolve) => { waits = relay({ liloExternal: other, message: 'ping' }, sender, resolve); });
    answer = undefined;

    assert.equal(waits, true);
    assert.deepEqual(relayed, { response: 'pong' });
    assert.deepEqual(gapCalls.at(-1)?.params, { id: other, message: 'ping', ...sender });
    assert.equal(relay('own', sender, () => {}), undefined, "the extension's own messages stay its listeners'");
  });
});

describe("ports between the extension's pages and worker, which Lilo relays", () => {
  const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
  // Lilo runs each port event as a task, which Node may run after a timer.
  const until = async (done: () => boolean) => { while (!done()) await tick(); };
  const own = 'ponmlkjihgfedcbaponmlkjihgfedcba';
  const noReceiver = 'Could not establish connection. Receiving end does not exist.';

  it('post at once and in order, before Lilo answers, and disconnect with lastError when none takes them', async () => {
    answer = () => new Promise(() => {});
    const runtime: any = crossExtensionMessaging({ id: own, connectNative() {}, connect() { throw new Error('WebKit connect'); } });
    const from = gapCalls.length;
    const port = runtime.connect({ name: 'state' });
    port.postMessage('first');
    port.postMessage('second');
    await tick();
    const calls = gapCalls.slice(from).filter((c) => c.namespace === 'runtime');
    answer = undefined;
    const portId = calls[0]?.params.portId;
    assert.deepEqual(calls.map((c) => c.method), ['connect', 'portPost']);
    assert.equal(calls[0].params.name, 'state');
    assert.deepEqual(calls[1].params, { portId, json: '["first","second"]' });
    const circular: any = {};
    circular.self = circular;
    assert.throws(() => port.postMessage(circular), TypeError, 'a message JSON cannot hold throws as it is posted');

    const heard: unknown[] = [];
    // Each message runs as a task of its own, as in Chrome: a microtask the first schedules runs before the second.
    port.onMessage.addListener((message: unknown) => { heard.push(message); queueMicrotask(() => heard.push('then')); });
    pushGapEvent({ namespace: 'runtime', event: 'portMessages', args: [portId, JSON.stringify([{ state: 1 }, { state: 2 }])] });
    const lastError = new Promise((resolve) => port.onDisconnect.addListener(() => resolve(liloLastError())));
    pushGapEvent({ namespace: 'runtime', event: 'portDisconnect', args: [portId, noReceiver] });
    assert.deepEqual(await lastError, { message: noReceiver });
    assert.deepEqual(heard, [{ state: 1 }, 'then', { state: 2 }, 'then']);
  });

  it('take a port Lilo relays to each listener of the context, which posts back on it, and decline one with none', async () => {
    const webKitOnConnect: any = Object.create({ addListener() {}, removeListener() {} });
    const event = onConnect(() => webKitOnConnect);
    const from = gapCalls.length;
    event.dispatch({ portId: 'p.1', name: 'state', sender: { id: own } });
    const ports: any[] = [];
    event.addListener((port: any) => ports.push(port));
    event.addListener((port: any) => ports.push(port));
    event.dispatch({ portId: 'p.2', name: 'state', sender: { id: own, url: `chrome-extension://${own}/popup.html` } });
    await until(() => ports.length === 2);
    assert.equal(ports.length, 2);
    assert.equal(ports[0], ports[1], 'one port for the context, as Chrome');
    assert.deepEqual(ports[0].sender, { id: own, url: `chrome-extension://${own}/popup.html` });
    return tick().then(() => {
      ports[0].postMessage('back');
      return tick();
    }).then(() => {
      const calls = gapCalls.slice(from).filter((c) => c.namespace === 'runtime').map((c) => [c.method, c.params.portId]);
      assert.deepEqual(calls, [['portDecline', 'p.1'], ['portAccept', 'p.2'], ['portPost', 'p.2']]);
    });
  });

  it('disconnect the ports of this context once its channel to Lilo closes', async () => {
    const webKitOnConnect: any = Object.create({ addListener() {}, removeListener() {} });
    const event = onConnect(() => webKitOnConnect);
    const ports: any[] = [];
    event.addListener((port: any) => ports.push(port));
    event.dispatch({ portId: 'c.1', name: 'state', sender: { id: own } });
    await until(() => ports.length === 1);
    const disconnected = new Promise((resolve) => ports[0].onDisconnect.addListener(() => resolve(liloLastError())));
    closeGapChannel();
    assert.equal(await disconnected, undefined);
    assert.throws(() => ports[0].postMessage('late'), /disconnected port/);
  });

  it("give a frame's port its own name and sender when its extension page relays it", async () => {
    const webKitOnConnect: any = Object.create({ addListener() {}, removeListener() {} });
    const event = onConnect(() => webKitOnConnect);
    const ports: any[] = [];
    event.addListener((port: any) => ports.push(port));
    const page = `chrome-extension://${own}/offscreen.html`;
    const frame = 'https://example.com/editor';
    event.dispatch({ portId: 'f.1', name: `x${frameMark}${encodeURIComponent(frame)}`, sender: { id: own, url: page } });
    await until(() => ports.length === 1);
    assert.equal(ports[0].name, 'x');
    assert.deepEqual(ports[0].sender, { id: own, url: frame, origin: 'https://example.com' });
  });
});

describe("ports tabs.connect opens to the extension's own pages", () => {
  const fakePort = (name: string) => {
    const port: any = {
      name, posted: [] as unknown[], disconnected: false, heard: [] as Array<(message: unknown) => void>, closed: [] as Array<() => void>,
      onMessage: { addListener: (listener: (message: unknown) => void) => port.heard.push(listener) },
      onDisconnect: { addListener: (listener: () => void) => port.closed.push(listener) },
      postMessage: (message: unknown) => port.posted.push(message),
      disconnect: () => { port.disconnected = true; },
    };
    return port;
  };
  const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
  // Lilo runs each port event as a task, which Node may run after a timer.
  const until = async (done: () => boolean) => { while (!done()) await tick(); };

  it('reach only the page the tab shows, which declines the others to Lilo', async () => {
    (globalThis as any).top = globalThis;
    (globalThis as any).location = { href: 'chrome-extension://own/popup.html' };
    const webKitOnConnect: any = Object.create({ addListener(this: any, listener: any) { this.listener = listener; }, removeListener() {} });
    const event = onConnect(() => webKitOnConnect);
    const heard: string[] = [];
    event.addListener((port: any) => heard.push(port.name));
    const from = gapCalls.length;
    event.dispatch({ portId: 't.1', name: 'panel?liloTab=chrome-extension://own/popup.html', sender: {} });
    event.dispatch({ portId: 't.2', name: 'panel?liloTab=chrome-extension://own/options.html', sender: {} });
    const external = fakePort('x?liloExternal=abcdefghijklmnopabcdefghijklmnop?lilo');
    webKitOnConnect.listener(external);
    await until(() => gapCalls.slice(from).filter((c) => c.namespace === 'runtime').length === 2);
    delete (globalThis as any).top;
    delete (globalThis as any).location;

    assert.deepEqual(heard, ['panel']);
    assert.deepEqual(gapCalls.slice(from).filter((c) => c.namespace === 'runtime').map((c) => [c.method, c.params.portId]), [['portAccept', 't.1'], ['portDecline', 't.2']]);
    assert.equal(external.disconnected, false, "a page leaves a content script's port to another extension to the worker");
  });

  it("disconnect with lastError when no script of a web page listens, where WebKit throws", async () => {
    (globalThis as any).chrome.runtime.getURL = (path: string) => `chrome-extension://own/${path}`;
    const tabs = { get: (id: number) => Promise.resolve({ id, url: 'https://example.com/' }) };
    const refuse = () => { throw new Error('Invalid call to tabs.connect(). No runtime.onConnect listeners found.'); };
    const port: any = tabsConnect(refuse, () => tabs).call(tabs, 5, { name: 'content' });
    assert.equal(port.name, 'content');
    port.postMessage('ping');
    const lastError = await new Promise((resolve) => port.onDisconnect.addListener(() => resolve(liloLastError())));
    assert.deepEqual(lastError, { message: 'Could not establish connection. Receiving end does not exist.' });
  });

  it('go to the page a tab shows, with what was posted meanwhile', async () => {
    const runtime = (globalThis as any).chrome.runtime;
    let page: any;
    runtime.getURL = (path: string) => `chrome-extension://own/${path}`;
    runtime.connect = (info: { name: string }) => (page = fakePort(info.name));
    const webKit = fakePort('panel');
    const tabs = { get: (id: number) => Promise.resolve({ id, url: 'chrome-extension://own/popup.html' }) };
    const port: any = tabsConnect(() => webKit, () => tabs).call(tabs, 5, { name: 'panel' });
    const heard: unknown[] = [];
    port.onMessage.addListener((message: unknown) => heard.push(message));
    port.postMessage('first');
    await tick();
    port.postMessage('second');
    page.heard.forEach((listener: (message: unknown) => void) => listener('back'));

    assert.equal(page.name, 'panel?liloTab=chrome-extension://own/popup.html');
    assert.deepEqual(page.posted, ['first', 'second']);
    assert.deepEqual(webKit.posted, ['first']);
    assert.equal(webKit.disconnected, true);
    assert.deepEqual(heard, ['back']);
    assert.equal(port.name, 'panel');
  });

  it("stay WebKit's for a web page, whose disconnect waits for the tab's url", async () => {
    const webKit = fakePort('');
    const tabs = { get: (id: number) => Promise.resolve({ id, url: 'https://example.com/' }) };
    const port: any = tabsConnect(() => webKit, () => tabs).call(tabs, 7);
    let disconnected = false;
    port.onDisconnect.addListener(() => { disconnected = true; });
    webKit.closed.forEach((listener: () => void) => listener());
    assert.equal(disconnected, false);
    await tick();

    assert.equal(disconnected, true);
    assert.throws(() => port.postMessage('late'), { message: 'Attempting to use a disconnected port object' });
  });
});

describe('runtime ports between extension pages and the worker', () => {
  /** WebKit's two ends of one channel; `queued` holds what is posted before it connects. */
  function channel() {
    const ends: any[] = [];
    let queued: unknown[] | null = [];
    const end = (name: string) => {
      const listeners: Array<(message: unknown) => void> = [];
      const port: any = {
        name,
        onMessage: { addListener: (listener: (message: unknown) => void) => listeners.push(listener) },
        onDisconnect: { addListener() {} },
        postMessage(message: unknown) {
          const json = JSON.stringify(message);
          if (queued) queued.push([port, json]);
          else for (const other of ends) if (other !== port) other.deliver(json);
        },
        deliver: (json: string) => { for (const listener of listeners) listener(JSON.parse(json)); },
      };
      ends.push(port);
      return port;
    };
    // WebKit fires the queue for the target world, then for the source world: both the main world.
    const connect = () => {
      const fired = queued!;
      queued = null;
      for (let round = 0; round < 2; round++) {
        for (const [from, json] of fired as Array<[any, string]>) for (const other of ends) if (other !== from) other.deliver(json);
      }
    };
    return { end, connect };
  }

  it('delivers each message posted before the port connects once, and repeated messages each time', () => {
    const { end, connect } = channel();
    let opened: any;
    const runtime: any = crossExtensionMessaging({ id: 'ponmlkjihgfedcbaponmlkjihgfedcba', connect: (info: any) => (opened = end(info.name)) });
    const page = runtime.connect({ name: 'popup' });
    const pageHeard: unknown[] = [];
    page.onMessage.addListener((message: unknown) => pageHeard.push(message));
    page.postMessage('state?');
    page.postMessage('state?');

    const webKitOnConnect: any = Object.create({ addListener(this: any, listener: any) { this.listener = listener; }, removeListener() {} });
    const workerHeard: unknown[] = [];
    onConnect(() => webKitOnConnect).addListener((port: any) => {
      assert.equal(port.name, 'popup');
      port.onMessage.addListener((message: unknown, from: unknown) => { assert.equal(from, port); workerHeard.push(message); });
      port.postMessage({ state: 1 });
    });
    webKitOnConnect.listener(end(opened.name));
    connect();
    page.postMessage('state?');

    assert.deepEqual(workerHeard, ['state?', 'state?', 'state?']);
    assert.deepEqual(pageHeard, [{ state: 1 }]);
  });

  it('keeps the name of a port connected with a null id first, as webext-redux connects', () => {
    const opened: string[] = [];
    const runtime: any = crossExtensionMessaging({ id: 'ponmlkjihgfedcbaponmlkjihgfedcba', connect: (info: any) => { opened.push(info.name); return channel().end(info.name); } });
    assert.equal(runtime.connect(null, { name: 'chromex.port_name' }).name, 'chromex.port_name');
    assert.equal(runtime.connect(undefined, { name: 'state' }).name, 'state');
    assert.deepEqual(opened.map((name) => name.split('?')[0]), ['chromex.port_name', 'state']);
  });

  it('hands out a port that disconnects with lastError when no context listens, where WebKit throws', async () => {
    const runtime: any = crossExtensionMessaging({
      id: 'ponmlkjihgfedcbaponmlkjihgfedcba',
      connect: () => { throw new Error('Invalid call to runtime.connect(). No runtime.onConnect listeners found.'); },
    });
    const port = runtime.connect({ name: 'chromex.port_name' });
    assert.equal(port.name, 'chromex.port_name');
    port.postMessage('before');
    const lastError = await new Promise((resolve) => port.onDisconnect.addListener(() => resolve(liloLastError())));
    assert.deepEqual(lastError, { message: 'Could not establish connection. Receiving end does not exist.' });
    assert.throws(() => port.postMessage('after'), /disconnected port/);
  });

  it('connects with its own onConnect listeners off WebKit event, so WebKit asks only the other processes', () => {
    const listeners = new Set<unknown>();
    const webKitOnConnect: any = Object.create({
      addListener: (listener: unknown) => listeners.add(listener),
      removeListener: (listener: unknown) => listeners.delete(listener),
    });
    const own = onConnect(() => webKitOnConnect);
    own.addListener(() => {});
    own.addListener(() => {});
    const { end } = channel();
    const heardWhileConnecting: number[] = [];
    const runtime: any = crossExtensionMessaging(
      { id: 'ponmlkjihgfedcbaponmlkjihgfedcba', connect: (info: any) => { heardWhileConnecting.push(listeners.size); return end(info.name); } },
      undefined,
      own,
    );
    runtime.connect({ name: 'back' });

    assert.deepEqual(heardWhileConnecting, [0]);
    assert.equal(listeners.size, 2);
  });

  it('drops what Lilo sends a channel to it that WebKit numbered as the port', () => {
    const { end, connect } = channel();
    const runtime: any = crossExtensionMessaging({ id: 'ponmlkjihgfedcbaponmlkjihgfedcba', connect: (info: any) => end(info.name) });
    const page = runtime.connect({ name: 'popup' });
    const heard: unknown[] = [];
    page.onMessage.addListener((message: unknown) => heard.push(message));
    const lilo = end('lilo');
    connect();
    lilo.postMessage({ reply: 1, result: null, liloChannel: 7 });

    assert.deepEqual(heard, []);
  });
});
