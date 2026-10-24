// chrome.i18n.detectLanguage, which WebKit omits: native answers with NLLanguageRecognizer.
//
// SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';

interface DetectedLanguages {
  isReliable: boolean;
  languages: { language: string; percentage: number }[];
}

export function detectLanguage(text: string, callback?: (result: DetectedLanguages) => void) {
  return callbackify(() => gapCall<DetectedLanguages>('i18n', 'detectLanguage', { text: String(text ?? '') }), callback);
}
