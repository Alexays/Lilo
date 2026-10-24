import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { CHROME_MAJOR, CHROME_VERSION, chromeUserAgent, showChromeUserAgent } from './chrome-version.ts';

describe('chromeUserAgent', () => {
  const webKit = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)';

  it("replaces Safari's tail and fills a worker's missing one", () => {
    assert.equal(chromeUserAgent(`${webKit} Version/26.0 Safari/605.1.15`), `${webKit} Chrome/${CHROME_VERSION} Safari/537.36`);
    assert.equal(chromeUserAgent(webKit), `${webKit} Chrome/${CHROME_VERSION} Safari/537.36`);
  });

  it('keeps one that already names Chrome', () => {
    const page = `${webKit} Chrome/${CHROME_VERSION} Safari/537.36`;
    assert.equal(chromeUserAgent(page), page);
  });
});

describe('showChromeUserAgent', () => {
  it("gives a worker Chrome's user agent and client hints", () => {
    const navigator = { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)' } as any;
    showChromeUserAgent(navigator);
    assert.ok(navigator.appVersion.includes(`Chrome/${CHROME_VERSION}`));
    assert.deepEqual(navigator.userAgentData.brands[0], { brand: 'Chromium', version: CHROME_MAJOR });
    assert.equal(navigator.userAgentData.platform, 'macOS');
    assert.equal('vendor' in navigator, false, "a worker's navigator has no vendor");
  });

  it("gives a page Chrome's vendor", () => {
    const navigator = { userAgent: 'Mozilla/5.0 AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15', vendor: 'Apple Computer, Inc.' } as any;
    showChromeUserAgent(navigator);
    assert.equal(navigator.vendor, 'Google Inc.');
  });
});
