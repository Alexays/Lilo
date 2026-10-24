import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// The worker prelude's global, from the bundled list.
(globalThis as any).__liloPublicSuffixList = readFileSync(new URL('../../../public-suffix-list.dat', import.meta.url), 'utf8');

const { publicSuffixAugmentation: ps } = await import('./publicSuffix.ts');

// Cases from Chromium's chrome/test/data/extensions/api_test/public_suffix and public_suffix_util_unittest.cc.
describe('publicSuffix', () => {
  it('knows suffixes, private ones included', () => {
    assert.equal(ps.isKnownSuffix('com'), true);
    assert.equal(ps.isKnownSuffix('COM'), true);
    assert.equal(ps.isKnownSuffix('co.uk'), true);
    assert.equal(ps.isKnownSuffix('foo.co.uk'), false);
    assert.equal(ps.isKnownSuffix('github.io'), true);
    assert.equal(ps.isKnownSuffix('foo.github.io'), false);
    assert.equal(ps.isKnownSuffix('localhost'), false);
    assert.equal(ps.isKnownSuffix('192.168.2.1'), false);
    assert.equal(ps.isKnownSuffix('jp.'), true);
    assert.equal(ps.isKnownSuffix('example.jp.'), false);

    assert.equal(ps.getKnownSuffix('foo.com'), 'com');
    assert.equal(ps.getKnownSuffix('www.example.co.uk'), 'co.uk');
    assert.equal(ps.getKnownSuffix('foo.github.io'), 'github.io');
    assert.equal(ps.getKnownSuffix('localhost'), null);
    assert.equal(ps.getKnownSuffix('192.168.2.1'), null);
    assert.equal(ps.getKnownSuffix('foo.中国'), 'xn--fiqs8s');
    assert.equal(ps.getKnownSuffix('example.jp.'), 'jp.');
  });

  it('applies wildcard and exception rules', () => {
    // *.ck with !www.ck
    assert.equal(ps.isKnownSuffix('ck'), true);
    assert.equal(ps.isKnownSuffix('foo.ck'), true);
    assert.equal(ps.getKnownSuffix('sub.foo.ck'), 'foo.ck');
    assert.equal(ps.isKnownSuffix('www.ck'), false);
    assert.equal(ps.getKnownSuffix('www.ck'), 'ck');
    assert.equal(ps.getDomain('www.ck'), 'www.ck');
    assert.equal(ps.getDomain('sub.www.ck'), 'www.ck');
    assert.equal(ps.getDomain('foo.ck'), null);
    assert.equal(ps.getDomain('a.foo.ck'), 'a.foo.ck');
  });

  it('returns the registrable domain', () => {
    assert.equal(ps.getDomain('sub.domain.com'), 'domain.com');
    assert.equal(ps.getDomain('www.mail.example.co.uk'), 'example.co.uk');
    assert.equal(ps.getDomain('EXAMPLE.JP'), 'example.jp');
    assert.equal(ps.getDomain('example.jp.'), 'example.jp.');
    assert.equal(ps.getDomain('com'), null);
    assert.equal(ps.getDomain('github.io'), null);
    assert.equal(ps.getDomain('foo.github.io'), 'foo.github.io');
    assert.equal(ps.getDomain('localhost'), null);
    assert.equal(ps.getDomain('192.168.2.1'), null);
    assert.equal(ps.getDomain('foo.中国'), 'foo.xn--fiqs8s');
  });

  it('honors the options', () => {
    assert.equal(ps.getDomain('foo.sub.localhost', { allowUnknownSuffix: true }), 'sub.localhost');
    assert.equal(ps.getDomain('localhost', { allowUnknownSuffix: true }), 'localhost');
    assert.equal(ps.getDomain('apple.pear.banana.', { allowUnknownSuffix: true }), 'pear.banana.');
    assert.equal(ps.getDomain('co.uk', { allowPlainSuffix: true }), 'co.uk');
    assert.equal(ps.getDomain('192.168.2.1', { allowIPAddress: true }), '192.168.2.1');
    assert.equal(ps.getDomain('[::1]', { allowIPAddress: true }), '[::1]');
    assert.equal(ps.getDomain('[::1]'), null);
    assert.equal(ps.getDomain('www.example.com', { encoding: 'display' }), 'example.com');
    assert.equal(ps.getDomain('foo.xn--fiqs8s', { encoding: 'display' }), 'foo.中国');
    assert.equal(ps.getDomain('www.xn--bcher-kva.de', { encoding: 'display' }), 'bücher.de');
    // Latin mixed with an Armenian lookalike stays punycode.
    assert.equal(ps.getDomain('xn--bs-red.com', { encoding: 'display' }), 'xn--bs-red.com');
  });

  it('throws on what is not a hostname', () => {
    for (const host of ['', '.', 'https://example.com', 'website.example/path', 'website.example:443', 'user@website.example',
      'website..example', '.example', '..website.example', '。website.example', 'website.example..', '*.com', '::1',
      '.192.168.2.1', '.[::1]', 'sub%2edomain.jp']) {
      assert.throws(() => ps.getDomain(host), /Invalid hostname/, host);
    }
    assert.throws(() => ps.isKnownSuffix('https://example.com'), {
      name: 'TypeError',
      message: 'Error in invocation of publicSuffix.isKnownSuffix(string hostname): Invalid hostname',
    });
    assert.equal(ps.getDomain('foo_bar.jp'), 'foo_bar.jp');
    assert.equal(ps.getDomain('example。jp'), 'example.jp');
  });
});
