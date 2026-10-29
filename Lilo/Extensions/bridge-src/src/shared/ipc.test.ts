// The worker's channel: it lets its port go when idle, so WebKit can unload it, without cutting a call
// or losing or repeating an event.
import { describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';

interface FakePort {
  sent: any[];
  disconnected: boolean;
  /** Lilo sends `message` stamped with the tag of the context the port is Lilo's channel of. */
  receive(message: object, to?: number): void;
  disconnect(): void;
}

const ports: FakePort[] = [];
/** The tag the context names itself with in its channels' first message. */
const tag = (): number => ports[0].sent[0].tag;
/** The id of the `index`th call the context made, which carries its tag in its high bits. */
const callId = (index: number): number => tag() * 2 ** 32 + index;
const dispatched: unknown[][] = [];
const listening = { dispatch: (...args: unknown[]) => dispatched.push(args) };
(globalThis as any).ServiceWorkerGlobalScope = function ServiceWorkerGlobalScope() {};
(globalThis as any).chrome = {
  bookmarks: { onCreated: listening, onRemoved: listening },
  proxy: { settings: { onChange: listening } },
  runtime: {
    id: 'x',
    onStartup: {},
    connectNative() {
      const onMessage: Array<(message: unknown) => void> = [];
      const onDisconnect: Array<() => void> = [];
      const port = {
        sent: [] as any[],
        disconnected: false,
        postMessage(message: unknown) { port.sent.push(message); },
        onMessage: { addListener: (listener: (message: unknown) => void) => onMessage.push(listener) },
        onDisconnect: { addListener: (listener: () => void) => onDisconnect.push(listener) },
        receive: (message: object, to = tag()) => onMessage.forEach((listener) => listener({ ...message, liloChannel: to })),
        disconnect: () => {
          port.disconnected = true;
          onDisconnect.forEach((listener) => listener());
        },
      };
      ports.push(port);
      return port;
    },
  },
};
// The worker's channel lives as long as the worker: here it must not keep the test process alive.
globalThis.BroadcastChannel = class extends BroadcastChannel {
  constructor(name: string) {
    super(name);
    (this as any).unref();
  }
};
mock.timers.enable({ apis: ['setTimeout', 'Date'] });
const { bridgeEvents, channelClosed, gapCall, workerNativeReady, workerReady } = await import('./ipc.ts');
const { startupStorageSettled, storageAreaPatches } = await import('./storage-area.ts');

describe('worker channel', () => {
  it('holds the events that arrive while the top-level code runs, then dispatches them in order, before storage answers', async () => {
    const call = gapCall('bookmarks', 'get', {}, 0);
    const read = storageAreaPatches.get(async () => 'stored', (area) => area as object).call({}).then((value: unknown) => dispatched.push([value]));
    let answerCallback!: () => void;
    storageAreaPatches.get((_keys: unknown, callback: (value: string) => void) => { answerCallback = () => callback('callback stored'); }, (area) => area as object)
      .call({}, null, (value: unknown) => dispatched.push([value]));
    const first = ports[0];
    assert.deepEqual(first.sent[0], { role: 'worker', tag: tag(), instance: (first.sent[0] as any).instance, ready: false });
    assert.equal(first.sent[1].id, callId(1));
    first.receive({ seq: 1, namespace: 'bookmarks', event: 'onCreated', args: [1] });
    first.receive({ events: [{ seq: 2, namespace: 'bookmarks', event: 'onRemoved', args: [2] }] });
    await new Promise(setImmediate);
    assert.deepEqual(dispatched, []);
    assert.equal(first.sent.some((message) => message.ready === true), false);
    workerReady();
    assert.equal(first.sent.some((message) => message.ready === true), false, 'native actions still wait for the startup storage read');
    let storageSettled = false;
    const startup = startupStorageSettled().then(() => { storageSettled = true; });
    await read;
    await new Promise(setImmediate);
    assert.equal(storageSettled, false, 'a pending startup callback keeps native actions waiting');
    answerCallback();
    await startup;
    workerNativeReady();
    assert.deepEqual(first.sent.at(-1), { ready: true, tag: tag() });
    await read;
    assert.deepEqual(dispatched.splice(0), [[1], [2], ['stored'], ['callback stored']]);
    first.receive({ reply: callId(1), result: 'done' });
    assert.equal(await call, 'done');
  });

  it('asks Lilo to close it once idle, never during a call, and opens a new port for the next call', async () => {
    const first = ports[0];
    const call = gapCall('bookmarks', 'get', {}, 0);
    mock.timers.tick(60_000);
    assert.equal(first.sent.some((message) => message.idle), false, 'a pending call keeps the port');
    first.receive({ reply: callId(2), result: 'done' });
    assert.equal(await call, 'done');

    mock.timers.tick(19_000);
    assert.equal(first.sent.some((message) => message.idle), false);
    mock.timers.tick(6_000);
    assert.deepEqual(first.sent.at(-1), { idle: true });

    const next = gapCall('bookmarks', 'get');
    assert.equal(ports.length, 2);
    assert.deepEqual(ports[1].sent[0], { role: 'worker', tag: tag(), instance: (ports[0].sent[0] as any).instance, ready: true });
    first.disconnect();
    ports[1].receive({ reply: callId(3), result: 'still answered' });
    assert.equal(await next, 'still answered', 'closing the idle port cuts no call of the new one');
  });

  it('dispatches an event Lilo sends again on a new port once', () => {
    const port = ports.at(-1)!;
    port.receive({ seq: 7, namespace: 'bookmarks', event: 'onCreated', args: [7] });
    port.receive({ seq: 7, namespace: 'bookmarks', event: 'onCreated', args: [7] });
    port.receive({ seq: 8, namespace: 'bookmarks', event: 'onRemoved', args: [8] });
    assert.deepEqual(dispatched.splice(0), [[7], [8]]);
  });

  it('fires the event an envelope names, nested by its dotted names, with its args spread', () => {
    const port = ports.at(-1)!;
    port.receive({ events: [{ namespace: 'proxy', event: 'settings.onChange', args: [{ mode: 'direct' }, 2] }, { namespace: 'bookmarks', event: 'onCreated' }] });
    assert.deepEqual(dispatched.splice(0), [[{ mode: 'direct' }, 2], []]);
  });

  it('ignores a malformed envelope, an unknown event or a member that is not one', () => {
    const port = ports.at(-1)!;
    for (const envelope of [{}, { namespace: 'nope', event: 'noop' }, { namespace: 'runtime', event: 'id' }, { namespace: 'runtime', event: 'onStartup' }, { event: 'onCreated' }]) {
      assert.doesNotThrow(() => port.receive(envelope));
    }
    assert.deepEqual(dispatched, []);
  });

  it('hands a state Lilo pushes to its handler while the port is open, and says when the port closes', () => {
    const port = ports.at(-1)!;
    const states: unknown[] = [];
    let closed = 0;
    bridgeEvents.set('test.state', (state) => states.push(state));
    channelClosed.push(() => { closed += 1; });

    port.receive({ push: 'test.state', args: [1] });
    mock.timers.tick(30_000);
    port.receive({ push: 'test.state', args: [2] });

    assert.deepEqual(port.sent.at(-1), { idle: true });
    assert.equal(closed, 1);
    assert.deepEqual(states, [1], 'what reaches a closed port is no longer kept current');
    assert.deepEqual(dispatched, []);
  });

  it('opens a new port when Lilo broadcasts that it holds an event', async () => {
    mock.timers.tick(30_000);
    assert.deepEqual(ports.at(-1)!.sent.at(-1), { idle: true });
    const count = ports.length;
    const lilo = new BroadcastChannel('lilo-reconnect');
    lilo.postMessage(0);
    lilo.close();
    for (let turn = 0; turn < 1000 && ports.length === count; turn++) await new Promise(setImmediate);
    assert.equal(ports.length, count + 1);
    assert.deepEqual(ports.at(-1)!.sent, [{ role: 'worker', tag: tag(), instance: (ports[0].sent[0] as any).instance, ready: true }]);
  });

  it("ignores what is not stamped with its tag: another port's messages, and Lilo's for another context", async () => {
    const port = ports.at(-1)!;
    const call = gapCall('bookmarks', 'get');
    const id = port.sent.at(-1).id;
    port.receive({ seq: 20, namespace: 'bookmarks', event: 'onCreated', args: ['other'] }, tag() + 1);
    port.receive({ reply: id, result: 'theirs' }, tag() + 1);
    port.receive({ reply: id, result: 'mine' });
    assert.equal(await call, 'mine');
    assert.deepEqual(dispatched, []);
  });

  it('sends what went on a channel Lilo says was given a taken number again on a new one, and keeps that one open', async () => {
    const taken = ports.at(-1)!;
    const call = gapCall('bookmarks', 'get');
    const sent = taken.sent.at(-1);
    taken.receive({ collided: true }, tag() + 1);
    assert.equal(ports.at(-1), taken, "another context's collision is not this one's");

    taken.receive({ collided: true });
    const next = ports.at(-1)!;
    assert.notEqual(next, taken);
    assert.equal(taken.disconnected, false);
    assert.deepEqual(next.sent, [{ role: 'worker', tag: tag(), instance: (ports[0].sent[0] as any).instance, ready: true }, sent]);
    next.receive({ reply: sent.id, result: 'moved' });
    assert.equal(await call, 'moved', 'the call survives the move');
  });
});
