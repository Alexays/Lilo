import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { installStaticChromeCompat } from './static-compat.ts';

describe('installStaticChromeCompat', () => {
  beforeEach(() => {
    delete (globalThis as any).window;
    (globalThis as any).chrome = { tabs: {} };
  });

  it('adds all Chrome tabs status constants without requiring window', () => {
    installStaticChromeCompat(globalThis as any);

    assert.equal((globalThis as any).chrome.tabs.TabStatus.UNLOADED, 'unloaded');
    assert.equal((globalThis as any).chrome.tabs.TabStatus.LOADING, 'loading');
    assert.equal((globalThis as any).chrome.tabs.TabStatus.COMPLETE, 'complete');
  });

  it('does not overwrite a native TabStatus object', () => {
    const native = { LOADING: 'native-loading' };
    (globalThis as any).chrome.tabs.TabStatus = native;

    installStaticChromeCompat(globalThis as any);

    assert.equal((globalThis as any).chrome.tabs.TabStatus, native);
  });
});

describe('installStaticChromeCompat runtime and DNR constants', () => {
  beforeEach(() => {
    (globalThis as any).chrome = { runtime: {}, declarativeNetRequest: { MAX_NUMBER_OF_REGEX_RULES: 7 } };
  });

  it('fills missing enums and constants without overwriting native ones', async () => {
    installStaticChromeCompat(globalThis as any);
    const c = (globalThis as any).chrome;

    assert.equal(c.runtime.PlatformOs.MAC, 'mac');
    assert.equal(c.runtime.OnInstalledReason.INSTALL, 'install');
    assert.equal(c.runtime.ContextType.OFFSCREEN_DOCUMENT, 'OFFSCREEN_DOCUMENT');
    assert.equal(c.declarativeNetRequest.ResourceType.MAIN_FRAME, 'main_frame');
    assert.equal(c.declarativeNetRequest.DYNAMIC_RULESET_ID, '_dynamic');
    assert.equal(c.declarativeNetRequest.MAX_NUMBER_OF_REGEX_RULES, 7);
    assert.equal(await c.declarativeNetRequest.getAvailableStaticRuleCount(), 30000);
  });
});

describe('the content compat bundle', () => {
  it('does its work once per world, however many content scripts entries run it', () => {
    const bundle = readFileSync(new URL('../../../ChromeContentCompat.js', import.meta.url), 'utf8');
    let reads = 0;
    const chrome = { storage: {} };
    const context = vm.createContext({ navigator: {}, get chrome() { reads++; return chrome; } });
    vm.runInContext(bundle, context);
    const first = reads;
    vm.runInContext(bundle, context);

    assert.ok(first > 0);
    assert.equal(reads, first, 'the second run reads nothing');
    assert.equal(typeof (chrome.storage as any).managed.get, 'function');
  });
});
