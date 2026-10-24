import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { INERT_FILTER, fromWebKit, webKitRegex, webKitRule, webKitStaticRulesets } from './dnr-rules.ts';
import { installChromeCompat } from './chrome-compat.ts';
import { mockGapAPI } from './ipc.testkit.ts';

describe('RE2 regexFilter in the subset WebKit compiles', () => {
  it('spells \\w, \\d and \\s as classes, in and out of brackets', () => {
    assert.equal(
      webKitRegex('^https?:\\/\\/([\\w-]+\\.)?duckduckgo\\.com\\/\\?extensioninstalled(?:=[^&]*)?$'),
      '^https?:\\/\\/([A-Za-z0-9_-]+\\.)?duckduckgo\\.com\\/\\?extensioninstalled(?:=[^&]*)?$',
    );
    assert.equal(webKitRegex('a\\d+\\Sb'), 'a[0-9]+[^\\t\\n\\f\\r ]b');
    assert.equal(webKitRegex('[[:alpha:]]x'), '[A-Za-z]x');
  });

  it('turns an alternative ending the pattern into an optional tail', () => {
    assert.equal(webKitRegex('.*\\/trace\\/mail\\/.*u=42($|&)'), '.*\\/trace\\/mail\\/.*u=42(?:(&).*)?$');
    assert.equal(webKitRegex('^https://duckduckgo\\.com/chrome_newtab(?:[?#]|$)'), '^https:\\/\\/duckduckgo\\.com\\/chrome_newtab(?:(?:[?#]).*)?$');
    assert.equal(webKitRegex('^http://(www\\.)?[^.]+\\.[^.]+(:|/|$)'), '^http:\\/\\/(www\\.)?[^.]+\\.[^.]+(?:([:/]).*)?$');
  });

  it('turns a start-of-text alternative into an optional head', () => {
    assert.equal(webKitRegex('(^|\\.)example\\.com/'), '^(?:.*(\\.))?example\\.com\\/');
  });

  it('merges single-character alternatives and unrolls counted repetition', () => {
    assert.equal(webKitRegex('a(?:b|c|[de])z'), 'a[bcde]z');
    assert.equal(webKitRegex('x[0-9]{2,4}y'), 'x[0-9][0-9][0-9]?[0-9]?y');
    assert.equal(webKitRegex('(?P<host>[a-z]+)\\.com'), '([a-z]+)\\.com');
  });

  it('gives up where one WebKit regex cannot say the same', () => {
    assert.equal(webKitRegex('.*(?:meips|proxy).*#(.*\\/trace\\/mail\\/.*)'), undefined);
    assert.equal(webKitRegex('a|b'), undefined);
    assert.equal(webKitRegex('\\bads\\b'), undefined);
    assert.equal(webKitRegex('(ab){2}'), undefined, 'copies of a capturing group renumber the groups');
    assert.equal(webKitRegex('a$b'), undefined);
  });
});

describe('rules WebKit rejects', () => {
  const chrome = { runtime: { id: 'abc', getURL: (path: string) => `chrome-extension://uuid${path}` } };
  (globalThis as any).chrome = chrome;

  it('redirects to the extension own pages through extensionPath', () => {
    const rule = { id: 1, action: { type: 'redirect', redirect: { url: 'chrome-extension://abc/page.html?x=1#y' } }, condition: { urlFilter: 'a' } };
    assert.deepEqual(webKitRule(rule).action.redirect, { extensionPath: '/page.html?x=1#y' });
    const own = { ...rule, action: { type: 'redirect', redirect: { url: 'chrome-extension://uuid/blocked.html' } } };
    assert.deepEqual(webKitRule(own).action.redirect, { extensionPath: '/blocked.html' });
  });

  it('cannot redirect to a data: URL', () => {
    assert.equal(webKitRule({ id: 9001, action: { type: 'redirect', redirect: { url: 'data:,?data=1' } }, condition: { urlFilter: 'a' } }), undefined);
  });

  it('drops the headers WebKit does not know', () => {
    const rule = { id: 1, action: { type: 'modifyHeaders', requestHeaders: [{ header: 'X-Kopernio-Plugin-Version', operation: 'set', value: '1' }, { header: 'Referer', operation: 'remove' }] }, condition: {} };
    assert.deepEqual(webKitRule(rule).action.requestHeaders, [{ header: 'Referer', operation: 'remove' }]);
    assert.equal(webKitRule({ ...rule, action: { type: 'modifyHeaders', requestHeaders: [rule.action.requestHeaders[0]] } }), undefined);
  });

  it('drops the resource types WebKit rejects, which it never loads', () => {
    const rule = { id: 27, action: { type: 'block' }, condition: { urlFilter: 'a', resourceTypes: ['script', 'object', 'webtransport'] } };
    assert.deepEqual(webKitRule(rule).condition.resourceTypes, ['script']);
    assert.equal(webKitRule({ ...rule, condition: { urlFilter: 'a', resourceTypes: ['object', 'csp_report', 'webbundle'] } }), undefined);
  });

  it('drops the empty exclusions WebKit rejects, which exclude nothing', () => {
    const rule = { id: 3, action: { type: 'block' }, condition: { urlFilter: 'a', excludedInitiatorDomains: [], excludedDomains: [], excludedRequestMethods: [], excludedTabIds: [] } };
    assert.deepEqual(webKitRule(rule).condition, { urlFilter: 'a', excludedTabIds: [] });
    const excluding = { ...rule, condition: { urlFilter: 'a', excludedInitiatorDomains: ['example.com'] } };
    assert.equal(webKitRule(excluding), excluding);
  });

  it('leaves what Chrome rejects too for WebKit to reject', () => {
    const invalid = { id: 1, action: { type: 'block' }, condition: { regexFilter: '(' } };
    assert.equal(webKitRule(invalid), invalid);
  });
});

describe('the declarativeNetRequest namespace', () => {
  function namespace() {
    const stored: any[] = [];
    const prototype = {
      async updateDynamicRules(options: { addRules?: any[] }) {
        for (const rule of options.addRules ?? []) {
          if (/\\w|\|/.test(rule.condition?.regexFilter ?? '')) throw new Error(`Rule with id ${rule.id} is invalid. \`regexFilter\` is not a supported regular expression.`);
        }
        stored.push(...(options.addRules ?? []));
      },
      async getDynamicRules() { return JSON.parse(JSON.stringify(stored)); },
      isRegexSupported(this: object, options: { regex: string }) {
        if (!prototype.isPrototypeOf(this)) return undefined;
        return Promise.resolve(/\\w|\|/.test(options.regex) ? { isSupported: false, reason: 'syntaxError' } : { isSupported: true });
      },
    };
    (globalThis as any).chrome = { runtime: { getManifest: () => ({}) }, declarativeNetRequest: Object.create(prototype) };
    installChromeCompat({});
    return { dnr: (globalThis as any).chrome.declarativeNetRequest, stored };
  }

  it('applies the rest of an update and answers with the extension own rules', async () => {
    const { dnr, stored } = namespace();
    const rules = [
      { id: 1, action: { type: 'block' }, condition: { regexFilter: '.*u=1($|&)' } },
      { id: 2, action: { type: 'redirect', redirect: { regexSubstitution: '\\1' } }, condition: { regexFilter: '.*(?:meips|proxy).*#(.*)' } },
      { id: 3, action: { type: 'block' }, condition: { urlFilter: 'ads' } },
    ];
    await dnr.updateDynamicRules({ addRules: rules });
    assert.equal(stored[0].condition.regexFilter, '.*u=1(?:(&).*)?$');
    assert.equal(stored[1].condition.regexFilter, '^lilo-inert-rule:', 'kept under its id, never matching');
    assert.equal(stored[2], rules[2]);
    assert.deepEqual(await dnr.getDynamicRules(), rules);
  });

  it('answers isRegexSupported detached, for the regex WebKit would compile', async () => {
    const { dnr } = namespace();
    const isRegexSupported = dnr.isRegexSupported;
    assert.deepEqual(await isRegexSupported({ regex: '[\\w-]+' }), { isSupported: true });
    assert.deepEqual(await isRegexSupported.call(globalThis, { regex: 'a' }), { isSupported: true }, 'a sloppy-mode caller passes the global');
    assert.deepEqual(await isRegexSupported({ regex: '(?:a|bc)' }), { isSupported: false, reason: 'syntaxError' });
  });

  it('runs updates one after the other, so a removal sees the rules added before it', async () => {
    const ids = new Set<number>();
    const applied = new Set<number>();
    const prototype = {
      // WebKit removes only the ids its last applied update left.
      async updateDynamicRules(options: { addRules?: any[]; removeRuleIds?: number[] }) {
        const removed = (options.removeRuleIds ?? []).filter((id) => applied.has(id));
        removed.forEach((id) => ids.delete(id));
        for (const rule of options.addRules ?? []) {
          if (ids.has(rule.id)) throw new Error(`Rule ${rule.id} does not have a unique ID.`);
          ids.add(rule.id);
        }
        await new Promise((resolve) => setTimeout(resolve, 5));
        applied.clear();
        ids.forEach((id) => applied.add(id));
      },
    };
    (globalThis as any).chrome = { runtime: { getManifest: () => ({}) }, declarativeNetRequest: Object.create(prototype) };
    installChromeCompat({});
    const dnr = (globalThis as any).chrome.declarativeNetRequest;
    const rule = { id: 1, action: { type: 'block' }, condition: { urlFilter: 'ads' } };
    const first = dnr.updateDynamicRules({ addRules: [rule] });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Promise.all([first, dnr.updateDynamicRules({ removeRuleIds: [1], addRules: [rule] })]);
    assert.deepEqual([...ids], [1]);
  });

  function countingNamespace(initial: any[] = []) {
    let rules = initial;
    const updates: any[] = [];
    const prototype = {
      async updateDynamicRules(options: { addRules?: any[]; removeRuleIds?: number[] }) {
        updates.push(options);
        const kept = rules.filter((rule) => !options.removeRuleIds?.includes(rule.id));
        for (const rule of options.addRules ?? []) {
          if (kept.some((other) => other.id === rule.id)) throw new Error(`Rule with id ${rule.id} does not have a unique ID.`);
          kept.push(rule);
        }
        await new Promise((resolve) => setTimeout(resolve, 5));
        rules = kept;
      },
      async getDynamicRules() { return rules; },
    };
    (globalThis as any).chrome = { runtime: { getManifest: () => ({}) }, declarativeNetRequest: Object.create(prototype) };
    installChromeCompat({});
    return { dnr: (globalThis as any).chrome.declarativeNetRequest, updates, ids: () => rules.map((rule) => rule.id) };
  }
  const block = (id: number) => ({ id, action: { type: 'block' }, condition: { urlFilter: `ads${id}` } });

  it('does not send an update that changes nothing', async () => {
    const { dnr, updates } = countingNamespace([block(1)]);
    assert.equal(await dnr.updateDynamicRules({ removeRuleIds: [2, 3] }), undefined);
    await dnr.updateDynamicRules({});
    await dnr.updateDynamicRules({ removeRuleIds: [1, 2] });
    assert.deepEqual(updates, [{ removeRuleIds: [1, 2], addRules: [] }]);
  });

  it('sends the calls made before an update starts as one, applied in order', async () => {
    const { dnr, updates, ids } = countingNamespace([block(1)]);
    const results = await Promise.all([
      dnr.updateDynamicRules({ addRules: [block(2)] }),
      dnr.updateDynamicRules({ removeRuleIds: [1, 2], addRules: [block(3)] }),
      dnr.updateDynamicRules({ removeRuleIds: [3], addRules: [block(3), block(4)] }),
    ]);
    assert.deepEqual(results, [undefined, undefined, undefined]);
    assert.deepEqual(updates, [{ removeRuleIds: [1, 2, 3], addRules: [block(3), block(4)] }]);
    assert.deepEqual(ids(), [3, 4]);

    const running = dnr.updateDynamicRules({ addRules: [block(5)] });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Promise.all([running, dnr.updateDynamicRules({ addRules: [block(6)] }), dnr.updateDynamicRules({ addRules: [block(7)] })]);
    assert.deepEqual(updates.slice(1), [{ removeRuleIds: [], addRules: [block(5)] }, { removeRuleIds: [], addRules: [block(6), block(7)] }]);
  });

  it('gives each call of a failed batch its own outcome', async () => {
    const { dnr, ids } = countingNamespace([block(1)]);
    const outcomes = await Promise.allSettled([
      dnr.updateDynamicRules({ addRules: [block(2)] }),
      dnr.updateDynamicRules({ addRules: [block(1)] }),
      dnr.updateDynamicRules({ addRules: [block(3)] }),
    ]);
    assert.deepEqual(outcomes.map((outcome) => outcome.status), ['fulfilled', 'rejected', 'fulfilled']);
    assert.match((outcomes[1] as PromiseRejectedResult).reason.message, /id 1 does not have a unique ID/);
    assert.deepEqual(ids(), [1, 2, 3]);

    const twice = await Promise.allSettled([dnr.updateDynamicRules({ addRules: [block(4)] }), dnr.updateDynamicRules({ addRules: [block(4)] })]);
    assert.deepEqual(twice.map((outcome) => outcome.status), ['fulfilled', 'rejected']);
    assert.deepEqual(ids(), [1, 2, 3, 4]);
  });

  it('sends updateEnabledRulesets only the rulesets that change', async () => {
    const calls: any[] = [];
    let enabled = ['on', 'both'];
    const prototype = {
      async getEnabledRulesets() { return enabled; },
      async updateEnabledRulesets(options: { enableRulesetIds: string[]; disableRulesetIds: string[] }) {
        calls.push(options);
        if (options.enableRulesetIds.includes('missing')) throw new Error('Failed to apply rules. Invalid ruleset id: missing.');
        enabled = [...enabled.filter((id) => !options.disableRulesetIds.includes(id)), ...options.enableRulesetIds];
      },
    };
    const rule_resources = ['on', 'off', 'both'].map((id) => ({ id, path: `${id}.json`, enabled: id !== 'off' }));
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ declarative_net_request: { rule_resources } }) }, declarativeNetRequest: Object.create(prototype) };
    installChromeCompat({});
    const dnr = (globalThis as any).chrome.declarativeNetRequest;
    await assert.rejects(dnr.updateEnabledRulesets({ disableRulesetIds: ['off', 'both', 'on'], enableRulesetIds: ['both', 'on', 'missing'] }), /missing/);
    assert.deepEqual(calls[0], { disableRulesetIds: [], enableRulesetIds: ['missing'] }, 'an unknown id stays for WebKit to reject');
    await dnr.updateEnabledRulesets({ disableRulesetIds: ['on', 'on', 'off'] });
    assert.deepEqual(calls[1], { disableRulesetIds: ['on'], enableRulesetIds: [] });
    assert.deepEqual(enabled, ['both']);
  });

  it('waits for WebKit first compile to turn every ruleset off', async () => {
    let attempts = 0;
    const prototype = {
      async getEnabledRulesets() { return ['on']; },
      async getDynamicRules() { return []; },
      async getSessionRules() { return []; },
      async updateEnabledRulesets() {
        if (++attempts < 3) throw new Error('Invalid call to declarativeNetRequest.updateEnabledRulesets(). Failed to apply rules.');
      },
    };
    const rule_resources = [{ id: 'on', path: 'on.json', enabled: true }];
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ declarative_net_request: { rule_resources } }) }, declarativeNetRequest: Object.create(prototype) };
    installChromeCompat({});
    await (globalThis as any).chrome.declarativeNetRequest.updateEnabledRulesets({ disableRulesetIds: ['on'] });
    assert.equal(attempts, 3);
  });

  it('disables static rules through native, then recompiles an enabled ruleset', async () => {
    const gapCalls: any[] = [];
    let changed = true;
    mockGapAPI(({ namespace, method, params }) => {
      if (namespace !== 'declarativeNetRequest') return null;
      gapCalls.push({ method, params });
      return method === 'getDisabledRuleIds' ? [3] : changed;
    });
    const toggles: any[] = [];
    const prototype = {
      async getEnabledRulesets() { return ['on']; },
      async updateEnabledRulesets(options: any) { toggles.push(options); },
    };
    const rule_resources = ['on', 'off'].map((id) => ({ id, path: `${id}.json`, enabled: id === 'on' }));
    (globalThis as any).chrome = { runtime: { getManifest: () => ({ declarative_net_request: { rule_resources } }) }, declarativeNetRequest: Object.create(prototype) };
    installChromeCompat({});
    const dnr = (globalThis as any).chrome.declarativeNetRequest;

    assert.deepEqual(await dnr.getDisabledRuleIds({ rulesetId: 'on' }), [3]);
    await dnr.updateStaticRules({ rulesetId: 'on', disableRuleIds: [3] });
    assert.deepEqual(gapCalls[1], { method: 'updateStaticRules', params: { rulesetId: 'on', disableRuleIds: [3], enableRuleIds: [] } });
    // WebKit reads the rewritten file when the ruleset turns on again, in the same update.
    assert.deepEqual(toggles, [{ disableRulesetIds: ['on'], enableRulesetIds: ['on'] }]);
    await dnr.updateStaticRules({ rulesetId: 'off', enableRuleIds: [3] });
    changed = false;
    await dnr.updateStaticRules({ rulesetId: 'on', enableRuleIds: [3] });
    assert.equal(toggles.length, 1, 'a disabled ruleset and an unchanged file need no compile');
  });
});

describe('static rulesets', () => {
  const block = (id: number, condition: object) => ({ id, action: { type: 'block' }, condition });

  it('puts each rule in the form WebKit applies, inert where it cannot be, once', () => {
    const rules = [block(1, { regexFilter: 'a\\d+' }), block(2, { regexFilter: '\\bads\\b' }), block(3, { urlFilter: 'ads' })];
    const [prepared, asWritten, broken] = webKitStaticRulesets([`\uFEFF${JSON.stringify(rules)}`, JSON.stringify([rules[2]]), '[{']);
    const applied = JSON.parse(prepared!);
    assert.equal(applied[0].condition.regexFilter, 'a[0-9]+');
    assert.equal(applied[1].condition.regexFilter, INERT_FILTER);
    assert.deepEqual(applied[2], rules[2]);
    assert.deepEqual(fromWebKit(applied), rules, 'each changed rule keeps the extension own');
    assert.equal(asWritten, null);
    assert.equal(broken, null, 'WebKit reports the JSON error itself');
    assert.deepEqual(webKitStaticRulesets([prepared!]), [prepared], 'preparing again changes nothing');
  });

  it('prepares a data: redirect without URL, which the preparer bare JavaScriptCore context lacks', (t) => {
    t.mock.property(globalThis, 'URL', undefined as any);
    const rules = [{ id: 1, action: { type: 'redirect', redirect: { url: 'data:,x' } }, condition: { urlFilter: 'a' } }, block(2, { regexFilter: 'a\\d' })];
    const applied = JSON.parse(webKitStaticRulesets([JSON.stringify(rules)])[0]!);
    assert.deepEqual(applied.map((rule: any) => rule.condition.regexFilter), [INERT_FILTER, 'a[0-9]']);
  });

  it('keeps every enabled set under WebKit cap, the rules WebKit expands most turning inert', () => {
    const domains = (count: number, name: string) => Array.from({ length: count }, (_, i) => `${name}${i}.example`);
    const [first, second] = webKitStaticRulesets([
      JSON.stringify([block(1, { requestDomains: domains(70000, 'a') }), block(2, { urlFilter: 'ads' })]),
      JSON.stringify([block(1, { requestDomains: domains(60000, 'b') }), block(2, { excludedRequestDomains: domains(30000, 'c') })]),
    ]);
    assert.deepEqual(JSON.parse(first!).map((rule: any) => rule.condition.regexFilter === INERT_FILTER), [true, false]);
    assert.equal(second, null, 'the rest fits');
  });
});
