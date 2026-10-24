import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { skipEmptyImports } from './empty-imports.ts';

const worker = (emptyPaths: string[]) => {
  const imported: string[][] = [];
  const scope: any = {
    location: { href: 'chrome-extension://abc/js/background.js' },
    importScripts(...urls: string[]) { imported.push(urls); },
  };
  skipEmptyImports(scope, emptyPaths);
  return { scope, imported };
};

describe('skipEmptyImports', () => {
  it('skips the extension\'s empty scripts, however the worker names them', () => {
    const { scope, imported } = worker(['/test.js', '/js/blank file.js']);
    scope.importScripts('/test.js');
    scope.importScripts('../test.js?v=1');
    scope.importScripts('blank%20file.js');
    scope.importScripts('chrome-extension://abc/test.js');
    assert.deepEqual(imported, []);
  });

  it('imports every other script, in order', () => {
    const { scope, imported } = worker(['/test.js']);
    scope.importScripts('a.js', '/test.js', 'b.js');
    scope.importScripts('chrome-extension://other/test.js');
    scope.importScripts();
    assert.deepEqual(imported, [['a.js', 'b.js'], ['chrome-extension://other/test.js'], []]);
  });

  it('leaves importScripts alone without empty scripts', () => {
    const importScripts = () => {};
    const scope: any = { location: { href: 'chrome-extension://abc/background.js' }, importScripts };
    skipEmptyImports(scope, []);
    assert.equal(scope.importScripts, importScripts);
  });
});
