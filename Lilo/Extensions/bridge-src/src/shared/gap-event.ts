// Each GapChromeEvent tells Lilo it is listened to; ipc.ts fires it when its envelope arrives.
// SW-safe: no window/document/webkit. (assert-background-prelude-safe.mjs)

import { ChromeEvent } from './chrome-event.ts';
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

/** A ChromeEvent native pushes as `namespace.event`, reported on its first listener. */
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

export function createGapEventsFromNames(namespace: string, eventNames: string[]): Record<string, ChromeEvent<any>> {
  const events: Record<string, ChromeEvent<any>> = {};
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
