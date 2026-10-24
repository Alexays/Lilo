import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI, pushGapEvent } from '../shared/ipc.testkit.ts';

const calls: any[] = [];
mockGapAPI(async (msg: any) => { calls.push(msg); return []; });
(globalThis as any).chrome = {
  runtime: { getManifest: () => ({ permissions: ['system.display', 'system.storage', 'power'] }) },
};

const { installGapAPIs } = await import('../shared/install-gap-apis.ts');
const { installChromeCompat } = await import('../shared/chrome-compat.ts');
installGapAPIs((globalThis as any).chrome);
installChromeCompat({});
const chrome = (globalThis as any).chrome;

describe('chrome.system', () => {
  it('installs only the sub-namespaces the manifest declares', () => {
    assert.deepEqual(Object.keys(chrome.system).sort(), ['display', 'storage']);
  });

  it('delivers a native event to a nested namespace', () => {
    const detached: string[] = [];
    chrome.system.storage.onDetached.addListener((id: string) => detached.push(id));
    pushGapEvent({ namespace: 'system.storage', event: 'onDetached', args: ['abc'] });
    assert.deepEqual(detached, ['abc']);
  });

  it('calls native for getInfo, with or without flags', async () => {
    await chrome.system.display.getInfo();
    await new Promise((resolve) => chrome.system.display.getInfo(resolve));
    await new Promise((resolve) => chrome.system.display.getInfo({ singleUnified: true }, resolve));
    assert.equal(calls.filter((c) => c.namespace === 'system.display' && c.method === 'getInfo').length, 3);
  });

  it('rejects the ChromeOS-only display calls as Chrome does on macOS', async () => {
    const count = calls.length;
    await assert.rejects(() => chrome.system.display.setDisplayProperties('1', {}), { message: 'Function available only on ChromeOS.' });
    await assert.rejects(() => chrome.system.display.getDisplayLayout(), { message: 'Function available only on ChromeOS.' });
    const lastError = await new Promise((resolve) => chrome.system.display.setMirrorMode({ mode: 'off' }, () => resolve(chrome.runtime.lastError?.message)));
    assert.equal(lastError, 'Function available only on ChromeOS.');
    assert.equal(calls.length, count, 'no native round trip');
  });
});

describe('chrome.power', () => {
  it('validates the level like Chrome and sends a valid one', () => {
    assert.throws(() => chrome.power.requestKeepAwake('screen'), {
      name: 'TypeError',
      message: "Error in invocation of power.requestKeepAwake(power.Level level): Error at parameter 'level': Value must be one of display, system.",
    });
    assert.equal(chrome.power.requestKeepAwake('display'), undefined);
    assert.deepEqual(calls.at(-1), { namespace: 'power', method: 'requestKeepAwake', params: { level: 'display' } });
  });
});
