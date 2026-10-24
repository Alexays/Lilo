import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI, pushGapEvent } from '../shared/ipc.testkit.ts';

const calls: Array<{ namespace: string; method: string; params: any }> = [];
let failSpeak = false;

mockGapAPI(async (msg: any) => {
  calls.push(msg);
  if (msg.method === 'speak' && failSpeak) throw new Error('Invalid rate.');
  return undefined;
});
(globalThis as any).chrome = { runtime: {} };

const { ttsAugmentation } = await import('./tts.ts');
(globalThis as any).chrome.tts = ttsAugmentation;

const speakCall = () => calls.filter((c) => c.method === 'speak').at(-1)!;

describe('tts', () => {
  beforeEach(() => {
    calls.length = 0;
    failSpeak = false;
  });

  it('keeps onEvent in the context and sends the rest of the options', async () => {
    const heard: any[] = [];
    await ttsAugmentation.speak('Hello', { rate: 2, onEvent: (event: any) => heard.push(event.type) });
    const { params } = speakCall();
    assert.equal(params.options.rate, 2);
    assert.equal('onEvent' in params.options, false);
    assert.equal(typeof params.srcId, 'number');

    pushGapEvent({ namespace: 'tts', event: 'onEvent', args: [{ type: 'start', srcId: params.srcId, isFinalEvent: false }] });
    pushGapEvent({ namespace: 'tts', event: 'onEvent', args: [{ type: 'start', srcId: params.srcId + 1, isFinalEvent: false }] });
    pushGapEvent({ namespace: 'tts', event: 'onEvent', args: [{ type: 'end', srcId: params.srcId, isFinalEvent: true }] });
    pushGapEvent({ namespace: 'tts', event: 'onEvent', args: [{ type: 'end', srcId: params.srcId, isFinalEvent: true }] });
    assert.deepEqual(heard, ['start', 'end'], 'another utterance and events after the final one are not heard');
  });

  it('sends no srcId without onEvent and takes a callback in place of the options', async () => {
    await new Promise<void>((resolve) => ttsAugmentation.speak('Hi', resolve));
    assert.equal(speakCall().params.srcId, undefined);
    assert.deepEqual(speakCall().params.options, {});
  });

  it('rejects with the native error and forgets the handler', async () => {
    failSpeak = true;
    const heard: any[] = [];
    await assert.rejects(() => ttsAugmentation.speak('Hi', { rate: 20, onEvent: (e: any) => heard.push(e) })!, /Invalid rate\./);
    pushGapEvent({ namespace: 'tts', event: 'onEvent', args: [{ type: 'error', srcId: speakCall().params.srcId, isFinalEvent: true }] });
    assert.deepEqual(heard, []);
  });

  it('keeps its internal event out of enumeration', () => {
    assert.equal(Object.keys(ttsAugmentation).includes('onEvent'), false);
    assert.equal(typeof (ttsAugmentation as any).onEvent.dispatch, 'function');
  });
});
