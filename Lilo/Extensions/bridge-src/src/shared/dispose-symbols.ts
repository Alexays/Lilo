// Chrome's `Symbol.dispose` and `Symbol.asyncDispose`, which WebKit leaves off: TypeScript's compiled `using` throws
// without them. SW-safe: no window/document/webkit.

/** Defines the missing ones as the registered symbols compilers fall back to, shared by every frame like a well-known symbol. */
export function installDisposeSymbols(symbol: SymbolConstructor): void {
  for (const name of ['dispose', 'asyncDispose']) {
    if (!(name in symbol)) Object.defineProperty(symbol, name, { value: Symbol.for(`Symbol.${name}`) });
  }
}
