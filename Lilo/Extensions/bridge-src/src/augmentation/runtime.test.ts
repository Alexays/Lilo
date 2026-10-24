import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method });
  return Promise.resolve(nextResult);
});
(globalThis as any).chrome = { runtime: {} };

const { runtimeAdditions, crossExtensionMessaging, onConnect } = await import('./runtime.ts');
const { liloLastError } = await import('../shared/callbackify.ts');

describe('runtime.requestUpdateCheck', () => {
  it('resolves the promise with native status and version', async () => {
    nextResult = { status: 'update_available', version: '2.0' };

    assert.deepEqual(await runtimeAdditions.requestUpdateCheck(), { status: 'update_available', version: '2.0' });
    assert.deepEqual(gapCalls.at(-1), { namespace: 'runtime', method: 'requestUpdateCheck' });
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

  it('rejects a promise and gives a callback lastError, as Chrome with no such extension', async () => {
    await assert.rejects(runtime.sendMessage(other, { a: 1 }), { message: noReceiver });
    const lastError = await new Promise((resolve) => runtime.sendMessage(other, 1, {}, () => resolve(liloLastError())));
    assert.deepEqual(lastError, { message: noReceiver });
    assert.equal(liloLastError(), undefined);
  });

  it('disconnects a port with lastError set while onDisconnect listeners run', async () => {
    const port = runtime.connect(other, { name: 'proxy' });
    assert.equal(port.name, 'proxy');
    const lastError = await new Promise((resolve) => port.onDisconnect.addListener(() => resolve(liloLastError())));
    assert.deepEqual(lastError, { message: noReceiver });
  });

  it("leaves the extension's own messages to WebKit", () => {
    webKitCalls.length = 0;
    assert.equal(runtime.sendMessage('a message'), 'webkit');
    assert.equal(runtime.sendMessage(other, () => {}), 'webkit');
    assert.equal(runtime.sendMessage(webKit.id, 1), 'webkit');
    assert.equal(webKitCalls.length, 3);
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
});
