// WebKit defers a worker's idle unload while a port was active in the last 2 minutes, so an idle worker says so after
// IDLE_MS and Lilo closes its port. SW-safe: assert-background-prelude-safe.mjs rejects window/document/webkit.

import { eventStandIns } from './chrome-event.ts';
import { bridgeChrome } from './callbackify.ts';

export const CHANNEL_HOST = 'app.lilo.channel';
const TIMEOUT_MS = 30_000;
// Below Chrome's 30 s, so a worker WebKit started unloads on WebKit's first idle check, 30 s after it
// started, as in Chrome.
const IDLE_MS = 20_000;
// Lilo broadcasts it from the worker's background page (BackgroundSupervisor.nudge).
const RECONNECT = 'lilo-reconnect';
const isWorker = typeof (globalThis as any).ServiceWorkerGlobalScope === 'function';

interface Port {
  postMessage(message: unknown): void;
  onMessage: { addListener(listener: (message: any) => void): void };
  onDisconnect: { addListener(listener: () => void): void };
}

interface PendingCall {
  port: Port;
  resolve(value: unknown): void;
  reject(error: Error): void;
  timer?: ReturnType<typeof setTimeout>;
}

let port: Port | undefined;
let ready = false;
let nextId = 1;
const pending = new Map<number, PendingCall>();
let lastActivity = 0;
let idleTimer: ReturnType<typeof setTimeout> | undefined;
// Lilo sends an event again on the worker's next port when it never learned it arrived.
let lastSeq = 0;
// Tells this worker from the next one on each port it opens: Lilo closes a stopped worker's sockets.
const instance = Math.random().toString(36).slice(2);
/** The events that reach the worker while its top-level code runs, dispatched once it is ready. */
const held: unknown[] = [];
let started: Promise<void> | undefined;
let start: (() => void) | undefined;

/** Events Lilo pushes to the bridge itself, outside Chrome's namespaces, by `namespace.event`. */
export const bridgeEvents = new Map<string, (...args: any[]) => void>();

function receive(envelope: unknown): void {
  if (isWorker && !ready) held.push(envelope);
  else dispatch(envelope);
}

/** Fires the ChromeEvent an event Lilo pushes names, with its args spread. */
function dispatch(envelope: any): void {
  if (typeof envelope?.seq === 'number') {
    if (envelope.seq <= lastSeq) return;
    lastSeq = envelope.seq;
  }
  if (typeof envelope?.namespace !== 'string' || typeof envelope.event !== 'string') return;
  const bridge = bridgeEvents.get(`${envelope.namespace}.${envelope.event}`);
  if (bridge) {
    bridge(...(Array.isArray(envelope.args) ? envelope.args : []));
    return;
  }
  // Dotted names nest one object per part: a namespace like `system.storage`, an event on a member
  // object like `proxy.settings.onChange`.
  const found = [...envelope.namespace.split('.'), ...envelope.event.split('.')]
    .reduce((object, key) => object?.[key], bridgeChrome());
  const event = eventStandIns.get(found) ?? found;
  if (typeof event?.dispatch === 'function') event.dispatch(...(Array.isArray(envelope.args) ? envelope.args : []));
}

function checkIdle(): void {
  const wait = lastActivity + IDLE_MS - Date.now();
  if (wait > 0 || pending.size > 0 || !ready) {
    idleTimer = setTimeout(checkIdle, wait > 0 ? wait : IDLE_MS / 4);
    return;
  }
  idleTimer = undefined;
  // Lilo closes the port, and wakes the worker again if it still holds an event; a call from now on
  // opens a new port.
  port?.postMessage({ idle: true });
  port = undefined;
}

if (isWorker) {
  new BroadcastChannel(RECONNECT).onmessage = () => connect();
}

function connect(): Port | undefined {
  if (port) return port;
  const runtime = bridgeChrome()?.runtime;
  // connectNative is only exposed with the nativeMessaging permission, which Lilo grants to every
  // loaded context.
  if (typeof runtime?.connectNative !== 'function') return undefined;
  const opened: Port = runtime.connectNative(CHANNEL_HOST);
  opened.onMessage.addListener((message) => {
    lastActivity = Date.now();
    if (typeof message?.reply === 'number') {
      const call = pending.get(message.reply);
      if (!call) return;
      pending.delete(message.reply);
      clearTimeout(call.timer);
      if (message.error != null) call.reject(new Error(message.error));
      else call.resolve(message.result);
    } else if (Array.isArray(message?.events)) {
      message.events.forEach(receive);
    } else {
      receive(message);
    }
  });
  opened.onDisconnect.addListener(() => {
    if (port === opened) port = undefined;
    for (const [id, call] of pending) {
      if (call.port !== opened) continue;
      clearTimeout(call.timer);
      call.reject(new Error('Lilo is unreachable'));
      pending.delete(id);
    }
  });
  port = opened;
  opened.postMessage(isWorker ? { role: 'worker', instance } : { role: 'page' });
  if (isWorker) {
    lastActivity = Date.now();
    idleTimer ??= setTimeout(checkIdle, IDLE_MS);
  }
  return opened;
}

/**
 * The worker's top-level code has run: the events that woke it, which Lilo sends once the worker's port
 * reached it, go to the listeners that code registered, as Chrome dispatches them right after it.
 */
export function workerReady(): void {
  ready = true;
  held.splice(0).forEach(dispatch);
  start?.();
  connect();
}

/** While the worker starts, the promise that settles once the events that woke it are dispatched. */
export function workerStarting(): Promise<void> | undefined {
  if (!isWorker || ready) return undefined;
  return (started ??= new Promise((resolve) => { start = resolve; }));
}

/**
 * Resolves with the handler's result and rejects with its error; a `timeoutMs` of 0 waits
 * indefinitely (a call the user answers, like an OAuth sign-in).
 */
export function gapCall<T>(namespace: string, method: string, params: unknown = {}, timeoutMs = TIMEOUT_MS): Promise<T> {
  const channel = connect();
  if (!channel) return Promise.reject(new Error('Gap API not available in this context'));
  const id = nextId++;
  return new Promise<T>((resolve, reject) => {
    const call: PendingCall = { port: channel, resolve: resolve as (value: unknown) => void, reject };
    if (timeoutMs > 0) {
      call.timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${namespace}.${method} timed out`));
      }, timeoutMs);
    }
    pending.set(id, call);
    channel.postMessage({ id, namespace, method, params });
  });
}
