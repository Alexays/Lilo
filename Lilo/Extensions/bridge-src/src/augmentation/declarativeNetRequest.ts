// What Lilo changes on WebKit's chrome.declarativeNetRequest: a gap module, so only a manifest naming one of its
// permissions pays for it. SW-safe: no window/document/webkit.
import { declarativeNetRequestPatches, staticRulesAdditions } from '../shared/dnr-rules.ts';
import type { NamespaceCompat } from '../shared/chrome-compat.ts';
import { ChromeEvent } from '../shared/chrome-event.ts';
import { testMatchOutcomeFor } from './dnrTestMatch.ts';

// Never fired: WebKit does not say which rule matched a request.
const onRuleMatchedDebug = new ChromeEvent<[unknown]>();

export function declarativeNetRequestCompat(dnr: object, feedback: boolean): NamespaceCompat {
  return {
    patch: declarativeNetRequestPatches,
    add: feedback ? { ...staticRulesAdditions, testMatchOutcome: testMatchOutcomeFor(dnr), onRuleMatchedDebug } : staticRulesAdditions,
  };
}
