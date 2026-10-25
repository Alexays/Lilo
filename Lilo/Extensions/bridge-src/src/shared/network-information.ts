// Chrome's Network Information API (`navigator.connection`), which WebKit lacks, for extension pages and the
// worker. SW-safe: no window/document/webkit.

type Scope = Pick<typeof globalThis, 'addEventListener' | 'navigator'>;

/**
 * Gives `navigator` Chrome's desktop `connection`. WebKit offers no estimate of the network's speed, so it reads as
 * the fast connection Chrome reports on broadband, with no speed offline; `change` fires as the network comes and goes.
 */
export function installNetworkInformation(scope: Scope): void {
  const navigator = scope.navigator;
  if (!navigator || 'connection' in navigator || typeof scope.addEventListener !== 'function') return;
  let onchange: ((this: EventTarget, event: Event) => unknown) | null = null;
  class NetworkInformation extends EventTarget {
    get effectiveType() { return '4g'; }
    get rtt() { return navigator.onLine ? 50 : 0; }
    get downlink() { return navigator.onLine ? 10 : 0; }
    get saveData() { return false; }
    get [Symbol.toStringTag]() { return 'NetworkInformation'; }
    get onchange() { return onchange; }
    set onchange(handler) { onchange = typeof handler === 'function' ? handler : null; }
  }
  const connection = new NetworkInformation();
  connection.addEventListener('change', (event) => onchange?.call(connection, event));
  const changed = () => connection.dispatchEvent(new Event('change'));
  scope.addEventListener('online', changed);
  scope.addEventListener('offline', changed);
  Object.defineProperty(navigator, 'connection', { get: () => connection, configurable: true, enumerable: true });
}
