// WebKit keeps only the first console.error argument and no stack, so debug builds record them whole; release builds
// refuse the call, and the context stops sending after the first refusal. SW-safe: no window/document/webkit.
import { gapCall } from './ipc.ts';

export function recordErrorDiagnostics(scope: typeof globalThis, source: 'page' | 'worker'): void {
  let recorded = true;
  const record = (values: unknown[]) => {
    if (!recorded) return;
    const message = values.map((value) => {
      if (value instanceof Error) return value.stack ? `${value.name}: ${value.message} ${value.stack}` : `${value.name}: ${value.message}`;
      if (typeof value === 'string') return value;
      try { return JSON.stringify(value) ?? String(value); } catch { return String(value); }
    }).join(' ');
    gapCall('diagnostics', 'console', { source, message: message.slice(0, 2000) }).catch(() => { recorded = false; });
  };
  const original = scope.console.error;
  scope.console.error = function (this: unknown, ...args: unknown[]) {
    if (args.length > 1 || typeof args[0] !== 'string') record(args);
    return original.apply(this, args);
  };
  scope.addEventListener?.('error', (event: any) => record([event.error ?? event.message]));
  scope.addEventListener?.('unhandledrejection', (event: any) => record([event.reason]));
}
