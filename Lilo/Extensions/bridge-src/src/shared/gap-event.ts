// Each GapChromeEvent tells Lilo it is listened to; ipc.ts fires it when its envelope arrives.
// SW-safe: no window/document/webkit. (assert-background-prelude-safe.mjs)

import { ChromeEvent, WrappedEvent } from './chrome-event.ts';
import { gapCall } from './ipc.ts';
import { callbackify } from './callbackify.ts';

/** Each reported listener's report, settled once native has answered it. */
const reports = new Map<string, Promise<unknown>>();
let unreportedListeners: string[] | undefined;
let batchAnswered: Promise<unknown> = Promise.resolve();
let answerBatch: (call: Promise<unknown>) => void = () => {};

function startBatch(): void {
  unreportedListeners = [];
  batchAnswered = new Promise((resolve) => { answerBatch = (call) => { call.then(resolve, resolve); }; });
}

function sendBatch(evenEmpty: boolean): void {
  const events = unreportedListeners ?? [];
  unreportedListeners = undefined;
  answerBatch(events.length > 0 || evenEmpty ? gapCall('events', 'listen', { events }) : Promise.resolve());
}

/**
 * Native only queues, and wakes the worker for, events a context listens to. A page's first listener is sent at
 * once, so an event emitted right after it is not filtered out; the rest batch until the task ends.
 */
export function reportGapListener(name: string): void {
  if (reports.has(name)) return;
  if (unreportedListeners) {
    unreportedListeners.push(name);
    reports.set(name, batchAnswered);
    return;
  }
  reports.set(name, gapCall('events', 'listen', { events: [name] }).catch(() => {}));
  startBatch();
  setTimeout(() => sendBatch(false), 0);
}

/** The context's last listener of `name` went: native stops sending it, and a stopped worker stops waking for it. */
function reportGapListenerRemoved(name: string): void {
  if (!reports.delete(name)) return;
  const batched = unreportedListeners?.indexOf(name) ?? -1;
  if (batched >= 0) unreportedListeners!.splice(batched, 1);
  else gapCall('events', 'unlisten', { events: [name] }).catch(() => {});
}

/** Settles once native has answered the report of the listener, undefined before any. */
export function gapListenerReported(name: string): Promise<unknown> | undefined {
  return reports.get(name);
}

/**
 * The worker collects the listeners its top-level code registers and reports them all at once, even
 * none, when that code has run: until then native wakes it for every gap event its permissions allow.
 */
export function collectGapListeners(): void {
  if (!unreportedListeners) startBatch();
}

export function sendGapListeners(): void {
  sendBatch(true);
}

/** A ChromeEvent native pushes as `namespace.event`, reported on its first listener and after its last. */
export class GapChromeEvent<T extends unknown[] = []> extends ChromeEvent<T> {
  private readonly gapName: string;

  constructor(namespace: string, event: string) {
    super();
    this.gapName = `${namespace}.${event}`;
  }

  override addListener(listener: (...args: T) => void): void {
    super.addListener(listener);
    reportGapListener(this.gapName);
  }

  override removeListener(listener: (...args: T) => void): void {
    super.removeListener(listener);
    if (!this.hasListeners()) reportGapListenerRemoved(this.gapName);
  }
}

/**
 * A WebKit event (a NamespaceCompat stand-in) native also pushes to as `namespace.event`: each listener hears WebKit's
 * through `wrap`, and native's through `receive`, which gets every listener with the arguments it was added with.
 */
export class GapWrappedEvent<T extends unknown[]> extends WrappedEvent<T> {
  private readonly added = new Map<(...args: T) => void, unknown[]>();
  private readonly gapName: string;
  private readonly receive: (listeners: [(...args: any[]) => unknown, unknown[]][], ...args: any[]) => void;

  constructor(
    gapName: string,
    source: () => object,
    wrap: (listener: (...args: T) => void) => (...args: any[]) => void,
    receive: (listeners: [(...args: any[]) => unknown, unknown[]][], ...args: any[]) => void,
  ) {
    super(source, wrap);
    this.gapName = gapName;
    this.receive = receive;
  }

  override addListener(listener: (...args: T) => void, ...rest: unknown[]): void {
    if (this.added.has(listener)) return;
    // WebKit may refuse what Chrome takes (an `asyncBlocking` listener): native's events still reach it.
    try { super.addListener(listener, ...rest); } catch { /* WebKit's event only */ }
    this.added.set(listener, rest);
    reportGapListener(this.gapName);
  }

  override removeListener(listener: (...args: T) => void): void {
    super.removeListener(listener);
    this.added.delete(listener);
  }

  override hasListener(listener: (...args: T) => void): boolean {
    return this.added.has(listener);
  }

  override hasListeners(): boolean {
    return this.added.size > 0;
  }

  override dispatch(...args: any[]): void {
    this.receive([...this.added], ...args);
  }
}

/** A GapChromeEvent whose native payload is resolved by `resolve`, in emission order; null drops it. */
export function resolvingEvent<Raw>(namespace: string, name: string, resolve: (raw: Raw) => Promise<unknown[] | null>): GapChromeEvent<any> {
  const event = new GapChromeEvent<any>(namespace, name);
  const fire = event.dispatch.bind(event);
  let delivered: Promise<void> = Promise.resolve();
  event.dispatch = (raw: Raw) => {
    if (!event.hasListeners() || !raw) return;
    delivered = delivered.then(() => resolve(raw)).then((args) => { if (args) fire(...args); }, () => { /* what it names went away */ });
  };
  return event;
}

export function createGapEventsFromNames<Name extends string>(namespace: string, eventNames: Name[]): Record<Name, ChromeEvent<any>> {
  const events = {} as Record<Name, ChromeEvent<any>>;
  for (const name of eventNames) events[name] = new GapChromeEvent(namespace, name);
  return events;
}

/**
 * A method Lilo answers: its arguments are named `names` in the call's params, or the first one is the
 * params; a last function argument is the callback.
 */
export function gapMethod(namespace: string, method: string, names?: string[]): (...args: any[]) => any {
  return (...args) => {
    const callback = typeof args.at(-1) === 'function' ? args.pop() : undefined;
    const params = names ? Object.fromEntries(names.map((name, index) => [name, args[index]])) : args[0] ?? {};
    return callbackify(() => gapCall(namespace, method, params), callback);
  };
}
