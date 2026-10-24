import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { matchOutcome, ruleMatches, testMatchOutcomeFor, DYNAMIC_RULESET_ID, SESSION_RULESET_ID, type Rule } from './dnrTestMatch.ts';
import { INERT_FILTER } from '../shared/dnr-rules.ts';

const rule = (id: number, type: string, condition: Rule['condition'], priority?: number): Rule => ({ id, priority, action: { type }, condition });
const script = { url: 'https://ads.example.com/track.js?x=1', type: 'script', initiator: 'https://news.site.org' };

describe('declarativeNetRequest urlFilter', () => {
  it('anchors on the domain with ||, on separators with ^, and spans with *', () => {
    assert.equal(ruleMatches(rule(1, 'block', { urlFilter: '||example.com^' }), script), true);
    assert.equal(ruleMatches(rule(1, 'block', { urlFilter: '||ample.com^' }), script), false);
    assert.equal(ruleMatches(rule(1, 'block', { urlFilter: 'track.js^' }), script), true);
    assert.equal(ruleMatches(rule(1, 'block', { urlFilter: '|https://ads.*track' }), script), true);
    assert.equal(ruleMatches(rule(1, 'block', { urlFilter: 'x=1|' }), script), true);
  });

  it('applies domains, resource types and party conditions', () => {
    assert.equal(ruleMatches(rule(1, 'block', { requestDomains: ['example.com'] }), script), true);
    assert.equal(ruleMatches(rule(1, 'block', { initiatorDomains: ['other.org'] }), script), false);
    assert.equal(ruleMatches(rule(1, 'block', { domainType: 'thirdParty' }), script), true);
    assert.equal(ruleMatches(rule(1, 'block', {}), { url: 'https://a.com/', type: 'main_frame' }), false, 'main frames need resourceTypes');
    assert.equal(ruleMatches(rule(1, 'block', { resourceTypes: ['main_frame'] }), { url: 'https://a.com/', type: 'main_frame' }), true);
  });
});

describe('declarativeNetRequest precedence', () => {
  it('lets the highest priority win, then allow over block, then session over dynamic over static', () => {
    const sources = [
      { rulesetId: 'static1', rules: [rule(1, 'block', { urlFilter: 'track' }, 2), rule(2, 'allow', { urlFilter: 'track' }, 1)] },
      { rulesetId: DYNAMIC_RULESET_ID, rules: [rule(3, 'block', { urlFilter: 'track' }, 2)] },
      { rulesetId: SESSION_RULESET_ID, rules: [rule(4, 'allow', { urlFilter: 'ads' }, 2)] },
    ];

    assert.deepEqual(matchOutcome(sources, script), [{ ruleId: 4, rulesetId: SESSION_RULESET_ID }]);
    assert.deepEqual(matchOutcome(sources.slice(0, 2), script), [{ ruleId: 3, rulesetId: DYNAMIC_RULESET_ID }]);
  });

  it('adds the header rules a winning allow does not outrank, and none behind a block', () => {
    const headers = rule(5, 'modifyHeaders', { urlFilter: 'track' }, 3);
    const allowed = matchOutcome([{ rulesetId: 's', rules: [rule(2, 'allow', { urlFilter: 'track' }, 2), headers] }], script);
    const blocked = matchOutcome([{ rulesetId: 's', rules: [rule(1, 'block', { urlFilter: 'track' }), headers] }], script);

    assert.deepEqual(allowed.map((m) => m.ruleId), [2, 5]);
    assert.deepEqual(blocked.map((m) => m.ruleId), [1]);
  });
});

describe('declarativeNetRequest.testMatchOutcome', () => {
  it('matches the static rules Lilo prepared as the extension wrote them, inert ones never', async () => {
    const written = [rule(1, 'block', { regexFilter: '\\btrack\\b' }, 2), rule(2, 'allow', { regexFilter: 'track\\.(js|css)' })];
    const prepared = [
      { id: 1, action: { type: 'block' }, condition: { regexFilter: INERT_FILTER }, liloChromeRule: written[0] },
      { id: 2, action: { type: 'allow' }, condition: { regexFilter: 'track\\.[jc]s' }, liloChromeRule: written[1] },
    ];
    const rule_resources = [{ id: 'rules', path: 'rules.json', enabled: true }];
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ declarative_net_request: { rule_resources } }), getURL: (path: string) => path } };
    (globalThis as any).fetch = async () => ({ json: async () => prepared });
    const dnr = { getEnabledRulesets: async () => ['rules'], getSessionRules: async () => [], getDynamicRules: async () => [] };
    assert.deepEqual(await testMatchOutcomeFor(dnr)(script), { matchedRules: [{ ruleId: 2, rulesetId: 'rules' }] });
  });
});
