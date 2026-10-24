// The Chrome version Lilo claims, as in ChromeMasquerade.chromeUserAgent (ChromeContractTests checks both).
export const CHROME_MAJOR = '155';
export const CHROME_VERSION = `${CHROME_MAJOR}.0.0.0`;

/**
 * Chrome's user agent from WebKit's: its `Version/... Safari/...` tail, or none (a worker has no
 * application name), becomes the one extension pages get from ChromeMasquerade.chromeApplicationName.
 */
export function chromeUserAgent(userAgent: string): string {
  if (userAgent.includes(' Chrome/')) return userAgent;
  return `${userAgent.replace(/ Version\/[\d.]+ Safari\/[\d.]+$/, '')} Chrome/${CHROME_VERSION} Safari/537.36`;
}

/** Shows extension code Chrome's user agent on `navigator`, in the world this runs in only. */
export function showChromeUserAgent(navigator: object): void {
  showChromeUserAgentData(navigator);
  const userAgent = chromeUserAgent((navigator as Navigator).userAgent);
  if (userAgent === (navigator as Navigator).userAgent) return;
  Object.defineProperty(navigator, 'userAgent', { get: () => userAgent, configurable: true });
  Object.defineProperty(navigator, 'appVersion', { get: () => userAgent.replace(/^Mozilla\//, ''), configurable: true });
  // Chrome's vendor goes with its user agent: Flutter tells Blink by it.
  if ('vendor' in navigator) Object.defineProperty(navigator, 'vendor', { get: () => 'Google Inc.', configurable: true });
}

/**
 * Chrome's `navigator.userAgentData`, which WebKit lacks: extensions read the Chrome version from its
 * brands (Browser Security Plus), and the store its platform.
 */
export function showChromeUserAgentData(navigator: any): void {
  if (navigator.userAgentData) return;
  const brands = [
    { brand: 'Chromium', version: CHROME_MAJOR },
    { brand: 'Google Chrome', version: CHROME_MAJOR },
    { brand: 'Not?A_Brand', version: '99' },
  ];
  const fullVersionList = [
    { brand: 'Chromium', version: CHROME_VERSION },
    { brand: 'Google Chrome', version: CHROME_VERSION },
    { brand: 'Not?A_Brand', version: '99.0.0.0' },
  ];
  const userAgentData = {
    brands, mobile: false, platform: 'macOS',
    getHighEntropyValues: (_hints: string[]) => Promise.resolve({
      architecture: 'x86', bitness: '64', brands, fullVersionList, mobile: false,
      model: '', platform: 'macOS', platformVersion: '15.0.0', uaFullVersion: CHROME_VERSION,
      wow64: false, formFactors: ['Desktop'],
    }),
    toJSON: () => ({ brands, mobile: false, platform: 'macOS' }),
  };
  Object.defineProperty(navigator, 'userAgentData', { get: () => userAgentData, configurable: true });
}
