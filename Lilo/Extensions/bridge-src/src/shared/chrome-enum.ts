/** A Chrome enum object as the bindings expose it: `{ SESSION_ONLY: 'session_only', ... }`. SW-safe. */
export function chromeEnum(values: string[]): Record<string, string> {
  return Object.fromEntries(values.map((value) => [value.replace(/-/g, '_').toUpperCase(), value]));
}
