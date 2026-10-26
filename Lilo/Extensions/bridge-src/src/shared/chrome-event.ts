type Listener<T extends unknown[]> = (...args: T) => void;

export class ChromeEvent<T extends unknown[] = []> {
  protected listeners: Set<Listener<T>> = new Set();

  addListener(listener: Listener<T>): void {
    this.listeners.add(listener);
  }

  removeListener(listener: Listener<T>): void {
    this.listeners.delete(listener);
  }

  hasListener(listener: Listener<T>): boolean {
    return this.listeners.has(listener);
  }

  hasListeners(): boolean {
    return this.listeners.size > 0;
  }

  /** Listeners as of now: one added during dispatch waits for the next event, as in Chrome. */
  protected snapshot(): Listener<T>[] {
    return [...this.listeners];
  }

  dispatch(...args: T): void {
    for (const listener of this.snapshot()) {
      try {
        listener(...args);
      } catch (err) {
        // Chrome's wording, in one string: WebKit reports only the first argument of a console.error.
        console.error(`Error in event handler: ${String(err)}`);
      }
    }
  }
}

/** WebKit events whose listeners go to Lilo's event instead (NamespaceCompat.standIns). */
export const eventStandIns = new WeakMap<object, ChromeEvent<any>>();

/**
 * Takes the listeners of WebKit's event `source()` (a NamespaceCompat stand-in): each listens to WebKit's
 * event through the wrapper `wrap` makes of it.
 */
export class WrappedEvent<T extends unknown[]> extends ChromeEvent<T> {
  private readonly wrappers = new Map<Listener<T>, Listener<any[]>>();
  private readonly source: () => object;
  private readonly wrap: (listener: Listener<T>) => Listener<any[]>;

  constructor(source: () => object, wrap: (listener: Listener<T>) => Listener<any[]>) {
    super();
    this.source = source;
    this.wrap = wrap;
  }

  /** WebKit's own event and its unpatched listener methods. */
  private native(): [object, Record<string, (...args: any[]) => unknown>] {
    const event = this.source();
    const prototype = Object.getPrototypeOf(event);
    const method = (name: string) => prototype[name].__liloUnwrapped ?? prototype[name];
    return [event, { add: method('addListener'), remove: method('removeListener') }];
  }

  addListener(listener: Listener<T>, ...rest: unknown[]): void {
    if (this.wrappers.has(listener)) return;
    const wrapper = this.wrap(listener);
    const [event, { add }] = this.native();
    add.call(event, wrapper, ...rest);
    this.wrappers.set(listener, wrapper);
  }

  removeListener(listener: Listener<T>): void {
    const wrapper = this.wrappers.get(listener);
    if (!wrapper) return;
    const [event, { remove }] = this.native();
    remove.call(event, wrapper);
    this.wrappers.delete(listener);
  }

  hasListener(listener: Listener<T>): boolean {
    return this.wrappers.has(listener);
  }

  hasListeners(): boolean {
    return this.wrappers.size > 0;
  }

  /** Runs `run` with the listeners off WebKit's event, which WebKit then counts this context out of, and back after. */
  unheard<R>(run: () => R): R {
    if (!this.wrappers.size) return run();
    const [event, { add, remove }] = this.native();
    for (const wrapper of this.wrappers.values()) remove.call(event, wrapper);
    try {
      return run();
    } finally {
      for (const wrapper of this.wrappers.values()) add.call(event, wrapper);
    }
  }
}

/** A ChromeEvent for each of `eventNames`, keyed by name. */
export function createChromeEventsFromNames(eventNames: string[]): Record<string, ChromeEvent<any>> {
  const events: Record<string, ChromeEvent<any>> = {};
  for (const name of eventNames) events[name] = new ChromeEvent();
  return events;
}
