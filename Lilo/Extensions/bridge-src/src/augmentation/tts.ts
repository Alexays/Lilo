import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { GapChromeEvent, gapMethod } from '../shared/gap-event.ts';

interface TtsEvent {
  type: string;
  srcId: number;
  isFinalEvent: boolean;
}

// As in Chrome's renderer, each utterance's onEvent stays in the calling context, keyed by a srcId,
// and native reports its progress on the internal tts.onEvent, which every context of the extension hears.
const handlers = new Map<number, (event: TtsEvent) => void>();
const utteranceEvents = new GapChromeEvent<[TtsEvent]>('tts', 'onEvent');
const onUtteranceEvent = (event: TtsEvent) => {
  const handler = handlers.get(event.srcId);
  if (!handler) return;
  if (event.isFinalEvent) handlers.delete(event.srcId);
  handler(event);
};

export const ttsAugmentation = {
  speak(utterance: string, options?: any, callback?: () => void) {
    if (typeof options === 'function') {
      callback = options;
      options = undefined;
    }
    const { onEvent, ...speechOptions } = options ?? {};
    let srcId: number | undefined;
    if (typeof onEvent === 'function') {
      // Ids only have to be unique among the extension's contexts, which all hear the events.
      do srcId = Math.floor(Math.random() * 2 ** 31); while (handlers.has(srcId));
      handlers.set(srcId, onEvent);
      if (!utteranceEvents.hasListener(onUtteranceEvent)) utteranceEvents.addListener(onUtteranceEvent);
    }
    return callbackify(() => gapCall<void>('tts', 'speak', { utterance, options: speechOptions, srcId }).catch((err) => {
      if (srcId !== undefined) handlers.delete(srcId);
      throw err;
    }), callback);
  },
  stop() {
    gapCall<void>('tts', 'stop').catch(() => {});
  },
  pause() {
    gapCall<void>('tts', 'pause').catch(() => {});
  },
  resume() {
    gapCall<void>('tts', 'resume').catch(() => {});
  },
  isSpeaking: gapMethod('tts', 'isSpeaking'),
  getVoices: gapMethod('tts', 'getVoices'),
  onVoicesChanged: new GapChromeEvent('tts', 'onVoicesChanged'),
};

// Internal in Chrome too: reachable for native's dispatch, absent from enumeration.
Object.defineProperty(ttsAugmentation, 'onEvent', { value: utteranceEvents, enumerable: false });
