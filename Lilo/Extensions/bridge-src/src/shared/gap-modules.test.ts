import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// The built page bundle, as WebKit injects it: a page evaluates only the gap modules its manifest uses.
const bundle = readFileSync(new URL('../../../ChromeAPIAugmentation.js', import.meta.url), 'utf8');

function runPage(manifest: object) {
  const evaluated: string[] = [];
  const factories = new Proxy({} as Record<string, unknown>, {
    set(target, name: string, factory: (core: unknown) => unknown) {
      target[name] = (core: unknown) => {
        evaluated.push(name);
        return factory(core);
      };
      return true;
    },
  });
  const context = vm.createContext({
    origin: 'chrome-extension://test',
    console,
    __liloGapModules: factories,
    chrome: { runtime: { getManifest: () => manifest }, tabs: {} },
  });
  vm.runInContext(bundle, context);
  return { chrome: context.chrome, evaluated, leftover: 'globalThis.__liloGapModules' in context };
}

describe('gap modules in the page bundle', () => {
  it('evaluates only the modules the manifest uses', () => {
    const { chrome, evaluated, leftover } = runPage({ permissions: ['history'] });

    assert.deepEqual(evaluated, ['history']);
    assert.equal(typeof chrome.history.search, 'function');
    assert.equal(chrome.bookmarks, undefined);
    assert.equal(leftover, false, 'the registry stays out of the page');
  });

  it('evaluates the module of an optional permission', () => {
    const { evaluated } = runPage({ permissions: [], optional_permissions: ['bookmarks'], omnibox: { keyword: 'k' } });

    assert.deepEqual(evaluated.sort(), ['bookmarks', 'omnibox']);
  });
});
