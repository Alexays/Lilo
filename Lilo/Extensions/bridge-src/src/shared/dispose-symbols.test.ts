import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { installDisposeSymbols } from './dispose-symbols.ts';

describe('installDisposeSymbols', () => {
  it('defines the missing symbols as the registered ones, read-only like a well-known symbol', () => {
    const symbol: any = {};
    installDisposeSymbols(symbol);
    assert.deepEqual(Object.getOwnPropertyDescriptor(symbol, 'dispose'), {
      value: Symbol.for('Symbol.dispose'), writable: false, enumerable: false, configurable: false,
    });
    assert.equal(symbol.asyncDispose, Symbol.for('Symbol.asyncDispose'));
  });

  it("keeps the engine's own", () => {
    const own = Symbol('Symbol.dispose');
    const symbol: any = { dispose: own };
    installDisposeSymbols(symbol);
    assert.equal(symbol.dispose, own);
    assert.equal(symbol.asyncDispose, Symbol.for('Symbol.asyncDispose'));
  });
});
