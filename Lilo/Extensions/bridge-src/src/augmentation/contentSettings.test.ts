import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(nextResult)));
});

(globalThis as any).chrome = { runtime: {} };

const { contentSettingsAugmentation: contentSettings } = await import('./contentSettings.ts');

describe('contentSettingsAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = null;
  });

  it('get sends the content type with the details and resolves with the setting', async () => {
    nextResult = { setting: 'block' };

    const result = await contentSettings.cookies.get({ primaryUrl: 'https://a.test/' });

    assert.deepEqual(result, { setting: 'block' });
    assert.deepEqual(gapCalls[0], { namespace: 'contentSettings', method: 'get', params: { primaryUrl: 'https://a.test/', type: 'cookies' } });
  });

  it('set throws Chrome\'s TypeError for a value the type does not take', () => {
    assert.throws(
      () => contentSettings.cookies.set({ primaryPattern: '<all_urls>', setting: 'ask' }),
      { name: 'TypeError', message: "Invalid invocation: Error at property 'setting': Value must be one of allow, block, session_only." },
    );
    assert.equal(gapCalls.length, 0);
  });

  it('set resolves with undefined once native stored the rule', async () => {
    const result = await contentSettings.camera.set({ primaryPattern: 'https://a.test/*', setting: 'ask' });

    assert.equal(result, undefined);
    assert.equal(gapCalls[0].params.type, 'camera');
  });

  it('getResourceIdentifiers resolves with undefined without asking native', async () => {
    assert.equal(await contentSettings.javascript.getResourceIdentifiers(), undefined);
    assert.equal(gapCalls.length, 0);
  });

  it('a retired type answers its callback at once and returns no promise', () => {
    const warn = console.warn;
    const warnings: unknown[] = [];
    console.warn = (message: unknown) => { warnings.push(message); };
    let got: unknown;
    try {
      const returned = contentSettings.unsandboxedPlugins.get({ primaryUrl: 'https://a.test/' }, (result: unknown) => { got = result; });
      assert.equal(returned, undefined);
      assert.equal(contentSettings.fullscreen.set({ primaryPattern: '<all_urls>', setting: 'block' }), undefined);
    } finally {
      console.warn = warn;
    }

    assert.deepEqual(got, { setting: 'block' });
    assert.deepEqual(warnings, ['contentSettings.ppapi-broker is deprecated.', 'contentSettings.fullscreen is deprecated.']);
    assert.equal(gapCalls.length, 0);
  });

  it('exposes Chrome\'s enum objects', () => {
    assert.deepEqual(contentSettings.Scope, { REGULAR: 'regular', INCOGNITO_SESSION_ONLY: 'incognito_session_only' });
    assert.equal(contentSettings.CookiesContentSetting.SESSION_ONLY, 'session_only');
  });
});
