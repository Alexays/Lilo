import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// The built page bundle, as WebKit injects it: a page evaluates only the gap modules its manifest uses.
const bundle = readFileSync(new URL('../../../ChromeAPIAugmentation.js', import.meta.url), 'utf8');

function runPage(manifest: object, webKit: object = {}) {
  const evaluated: string[] = [];
  const factories = new Proxy({} as Record<string, unknown>, {
    set(target, name: string, chunk: { constants: object; load: (core: unknown) => unknown }) {
      target[name] = {
        constants: chunk.constants,
        load: (core: unknown) => {
          evaluated.push(name);
          return chunk.load(core);
        },
      };
      return true;
    },
  });
  const context = vm.createContext({
    origin: 'chrome-extension://test',
    console,
    __liloGapModules: factories,
    chrome: { runtime: { getManifest: () => manifest }, tabs: {}, ...webKit },
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

  it('gives a namespace WebKit provides its constants without reading its module', () => {
    const { chrome, evaluated } = runPage({ permissions: ['notifications'] }, { notifications: {} });

    assert.equal(chrome.notifications.TemplateType.BASIC, 'basic');
    assert.deepEqual(evaluated, []);
  });

  it('reads the declarativeNetRequest module only once WebKit gives the namespace', () => {
    assert.deepEqual(runPage({ permissions: [] }).evaluated, []);

    const { chrome, evaluated } = runPage({ permissions: ['declarativeNetRequest'] }, { declarativeNetRequest: {} });
    assert.equal(typeof chrome.declarativeNetRequest.getDisabledRuleIds, 'function');
    assert.equal(chrome.declarativeNetRequest.testMatchOutcome, undefined);
    assert.equal(chrome.declarativeNetRequest.ResourceType.MAIN_FRAME, 'main_frame');
    assert.deepEqual(evaluated, ['declarativeNetRequest']);
  });
});

// The worker's prelude, as ExtensionBackgroundPreparer writes it: the chunks the manifest may need, then the bundle.
const prelude = readFileSync(new URL('../../../ChromeAPIBackgroundPrelude.js', import.meta.url), 'utf8');
const chunks: { needs: string[]; source: string }[] = JSON.parse(readFileSync(new URL('../../../ChromeAPIGapModules.json', import.meta.url), 'utf8'));

function runWorker(permissions: string[], webKit: object) {
  const source = chunks.filter((chunk) => chunk.needs.some((name) => permissions.includes(name))).map((chunk) => chunk.source).join('') + prelude;
  const context = vm.createContext({
    console: { ...console, error() {} },
    EventTarget,
    setTimeout,
    clearTimeout,
    chrome: { runtime: { getManifest: () => ({ permissions }) }, ...webKit },
  });
  vm.runInContext(source, context);
  return context.chrome;
}

describe('gap modules in the worker prelude', () => {
  it('carries the constants of the namespaces its manifest names, also where WebKit provides one', () => {
    const chrome = runWorker(['notifications', 'declarativeNetRequestWithHostAccess'], { notifications: {}, declarativeNetRequest: {}, tabs: {} });

    assert.equal(chrome.notifications.TemplateType.BASIC, 'basic');
    assert.equal(chrome.declarativeNetRequest.ResourceType.MAIN_FRAME, 'main_frame');
    assert.equal(typeof chrome.declarativeNetRequest.updateStaticRules, 'function');
    assert.equal(chrome.tabs.TAB_ID_NONE, -1);
  });

  it('leaves out the chunks of the namespaces its manifest does not name', () => {
    const chrome = runWorker([], { tabs: {} });

    assert.equal(prelude.includes('TemplateType'), false);
    assert.equal(prelude.includes('getDisabledRuleIds'), false);
    assert.equal(chrome.tabs.TAB_ID_NONE, -1);
  });
});
