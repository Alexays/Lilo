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

const { fontSettingsAugmentation: fontSettings } = await import('./fontSettings.ts');

describe('fontSettingsAugmentation', () => {
  beforeEach(() => {
    gapCalls.length = 0;
    nextResult = null;
  });

  it('a size getter takes its callback in place of the unused details', async () => {
    nextResult = { pixelSize: 16, levelOfControl: 'controllable_by_this_extension' };

    const result = await new Promise((resolve) => fontSettings.getDefaultFontSize(resolve));

    assert.deepEqual(result, { pixelSize: 16, levelOfControl: 'controllable_by_this_extension' });
    assert.deepEqual(gapCalls[0], { namespace: 'fontSettings', method: 'getDefaultFontSize', params: {} });
  });

  it('setters resolve with undefined', async () => {
    assert.equal(await fontSettings.setMinimumFontSize({ pixelSize: 12 }), undefined);
    assert.equal(await fontSettings.setFont({ genericFamily: 'standard', fontId: 'Georgia' }), undefined);
    assert.deepEqual(gapCalls.map((call) => call.method), ['setMinimumFontSize', 'setFont']);
  });

  it('font calls throw Chrome\'s TypeError for a script or family outside the enums, without asking native', () => {
    assert.throws(
      () => fontSettings.setFont({ genericFamily: 'standard', script: '', fontId: 'Georgia' }),
      { name: 'TypeError', message: /^Error in invocation of fontSettings\.setFont\(object details, optional function callback\): Error at parameter 'details': Error at property 'script': Value must be one of Afak, Arab, .*, Zyyy\.$/ },
    );
    assert.throws(
      () => fontSettings.getFont({ script: 'Latn' }),
      { name: 'TypeError', message: "Error in invocation of fontSettings.getFont(object details, optional function callback): Error at parameter 'details': Error at property 'genericFamily': Property is required." },
    );
    assert.throws(() => fontSettings.clearFont({ genericFamily: 'monospace' }), TypeError);
    assert.equal(gapCalls.length, 0);
  });

  it('exposes Chrome\'s enum objects', () => {
    assert.equal(fontSettings.ScriptCode.ZYYY, 'Zyyy');
    assert.equal(Object.keys(fontSettings.ScriptCode).length, 153);
    assert.equal(fontSettings.GenericFamily.SANSSERIF, 'sansserif');
  });
});
