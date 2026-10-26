import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI, pushGapEvent } from './ipc.testkit.ts';

const methods: string[] = [];
let nextId = 0;
mockGapAPI((msg) => {
  methods.push(msg.method);
  return msg.method === 'connect' ? ++nextId : null;
});

const { installWorkerWebSocket } = await import('./web-socket.ts');
const scope: any = {};
installWorkerWebSocket(scope);
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const receive = (event: object) => pushGapEvent({ namespace: 'webSocket', event: 'onEvent', args: [{ id: nextId, ...event }] });

test('a socket closed while connecting never opens', async () => {
  const socket = new scope.WebSocket('wss://example.test/feed');
  const heard: string[] = [];
  for (const type of ['open', 'close']) socket.addEventListener(type, () => heard.push(type));
  await settle();
  socket.close();
  receive({ type: 'open', protocol: '' });
  receive({ type: 'close', code: 1000, reason: '', wasClean: true });

  assert.equal(methods.at(-1), 'close');
  assert.equal(socket.readyState, scope.WebSocket.CLOSED);
  assert.deepEqual(heard, ['close']);
});

test('a message carries its bytes and the socket origin', async () => {
  const socket = new scope.WebSocket('ws://example.test:8080/feed');
  socket.binaryType = 'arraybuffer';
  const messages: MessageEvent[] = [];
  socket.onmessage = (event: MessageEvent) => messages.push(event);
  await settle();
  receive({ type: 'open', protocol: '' });
  receive({ type: 'message', binary: btoa(String.fromCharCode(0, 128, 255)) });
  receive({ type: 'message', text: 'hi' });

  assert.equal(socket.readyState, scope.WebSocket.OPEN);
  assert.deepEqual([...new Uint8Array(messages[0].data)], [0, 128, 255]);
  assert.equal(messages[0].origin, 'ws://example.test:8080');
  assert.equal(messages[1].data, 'hi');
});
