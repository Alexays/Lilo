import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { compileUrlFilters, type UrlFilter } from './url-filter.ts';

const matchesUrlFilter = (url: string, filter: UrlFilter) => compileUrlFilters([filter])!(new URL(url));

describe('UrlFilter', () => {
  const url = 'https://Docs.Example.com:8443/guide/start?lang=fr#intro';

  it('matches every criterion it sets', () => {
    assert.equal(matchesUrlFilter(url, { hostSuffix: 'example.com', pathPrefix: '/guide', queryContains: 'lang=' }), true);
    assert.equal(matchesUrlFilter(url, { hostSuffix: 'example.com', pathPrefix: '/api' }), false);
  });

  it('compares urls without the fragment and hosts in lower case', () => {
    assert.equal(matchesUrlFilter(url, { urlSuffix: 'lang=fr' }), true);
    assert.equal(matchesUrlFilter(url, { hostEquals: 'docs.example.com' }), true);
    assert.equal(matchesUrlFilter(url, { hostEquals: 'Docs.EXAMPLE.com', hostPrefix: 'DOCS', hostSuffix: 'Example.Com', hostContains: '.Example' }), true);
  });

  it('checks schemes, ports and regular expressions', () => {
    assert.equal(matchesUrlFilter(url, { schemes: ['https'], ports: [[8000, 9000]] }), true);
    assert.equal(matchesUrlFilter('http://a.com/', { ports: [80] }), true);
    assert.equal(matchesUrlFilter(url, { schemes: ['http'] }), false);
    assert.equal(matchesUrlFilter(url, { urlMatches: 'guide/start\\?' }), true);
    assert.equal(matchesUrlFilter(url, { originAndPathMatches: 'lang' }), false);
  });

  it('matches hosts with an implicit leading dot, as Chrome does', () => {
    assert.equal(matchesUrlFilter('https://foo.com/', { hostContains: '.foo' }), true);
    assert.equal(matchesUrlFilter('https://www.foobar.com/', { hostContains: '.foo' }), true);
    assert.equal(matchesUrlFilter('https://barfoo.com/', { hostContains: '.foo' }), false);
    assert.equal(matchesUrlFilter('https://foo.com/', { hostContains: 'com.' }), false);
    assert.equal(matchesUrlFilter('https://foo.com/', { hostEquals: '.foo.com' }), true);
    assert.equal(matchesUrlFilter('https://foo.com/', { hostPrefix: '.foo' }), true);
    assert.equal(matchesUrlFilter('https://foo.com/', { hostPrefix: 'foo' }), true);
    assert.equal(matchesUrlFilter('https://foo.com/', { hostSuffix: '.foo.com' }), true);
    assert.equal(matchesUrlFilter('https://barfoo.com/', { hostSuffix: '.foo.com' }), false);
  });

  it('matches when any filter of the list does, and has no matcher without one', () => {
    assert.equal(compileUrlFilters([{ hostEquals: 'nope.com' }, { pathEquals: '/guide/start' }])!(new URL(url)), true);
    assert.equal(compileUrlFilters(undefined), undefined);
    assert.equal(compileUrlFilters([]), undefined);
  });

  it('throws on an invalid regular expression when compiled', () => {
    assert.throws(() => compileUrlFilters([{ urlMatches: '(' }]), SyntaxError);
    assert.throws(() => compileUrlFilters([{ originAndPathMatches: '[' }]), SyntaxError);
  });
});
