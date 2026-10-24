// Lilo exposes none of these settings: each reports Chrome's default as not controllable, and set/clear do nothing.
// SW-safe: no window/document/webkit.
import { callbackify } from '../shared/callbackify.ts';
import { ChromeEvent } from '../shared/chrome-event.ts';

function chromeSetting(value: unknown) {
  return {
    get(_details: unknown, callback?: (result: { value: unknown; levelOfControl: string }) => void) {
      return callbackify(async () => ({ value, levelOfControl: 'not_controllable' }), callback);
    },
    set(_details: unknown, callback?: () => void) {
      return callbackify(async () => undefined, callback);
    },
    clear(_details: unknown, callback?: () => void) {
      return callbackify(async () => undefined, callback);
    },
    onChange: new ChromeEvent<[unknown]>(),
  };
}

function settings(defaults: Record<string, unknown>): Record<string, ReturnType<typeof chromeSetting>> {
  const out: Record<string, ReturnType<typeof chromeSetting>> = {};
  for (const [name, value] of Object.entries(defaults)) out[name] = chromeSetting(value);
  return out;
}

export const privacyAugmentation = {
  IPHandlingPolicy: {
    DEFAULT: 'default',
    DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: 'default_public_and_private_interfaces',
    DEFAULT_PUBLIC_INTERFACE_ONLY: 'default_public_interface_only',
    DISABLE_NON_PROXIED_UDP: 'disable_non_proxied_udp',
  },
  network: settings({
    networkPredictionEnabled: true,
    webRTCIPHandlingPolicy: 'default',
    webRTCMultipleRoutesEnabled: true,
    webRTCNonProxiedUdpEnabled: true,
  }),
  services: settings({
    alternateErrorPagesEnabled: true,
    autofillAddressEnabled: true,
    autofillCreditCardEnabled: true,
    autofillEnabled: true,
    passwordSavingEnabled: true,
    safeBrowsingEnabled: true,
    safeBrowsingExtendedReportingEnabled: false,
    searchSuggestEnabled: true,
    spellingServiceEnabled: false,
    translationServiceEnabled: true,
  }),
  websites: settings({
    adMeasurementEnabled: true,
    doNotTrackEnabled: false,
    fledgeEnabled: true,
    hyperlinkAuditingEnabled: true,
    referrersEnabled: true,
    relatedWebsiteSetsEnabled: true,
    thirdPartyCookiesAllowed: true,
    topicsEnabled: true,
  }),
};
