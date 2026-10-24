// WebKit applies the extension's rules but exposes no matcher, so this re-evaluates them with Chrome's matching and
// precedence; response-header conditions never match. SW-safe: chrome.* and fetch only.
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { INERT_FILTER, fromWebKit, webKitRule } from '../shared/dnr-rules.ts';

interface Condition {
  urlFilter?: string;
  regexFilter?: string;
  isUrlFilterCaseSensitive?: boolean;
  requestDomains?: string[];
  excludedRequestDomains?: string[];
  initiatorDomains?: string[];
  excludedInitiatorDomains?: string[];
  domains?: string[];
  excludedDomains?: string[];
  resourceTypes?: string[];
  excludedResourceTypes?: string[];
  requestMethods?: string[];
  excludedRequestMethods?: string[];
  tabIds?: number[];
  excludedTabIds?: number[];
  domainType?: 'firstParty' | 'thirdParty';
  responseHeaders?: unknown[];
  excludedResponseHeaders?: unknown[];
}

export interface Rule {
  id: number;
  priority?: number;
  action: { type: string };
  condition: Condition;
}

interface TestRequest {
  url: string;
  type: string;
  method?: string;
  initiator?: string;
  tabId?: number;
}

/** Where a rule comes from: Chrome breaks priority ties session first, then dynamic, then static. */
interface RuleSource {
  rulesetId: string;
  rules: Rule[];
}

export const SESSION_RULESET_ID = '_session';
export const DYNAMIC_RULESET_ID = '_dynamic';

// Chrome's tie-break between actions of equal priority.
const ACTION_ORDER = ['allow', 'allowAllRequests', 'block', 'upgradeScheme', 'redirect'];

function hostMatches(host: string, domains: string[]): boolean {
  return domains.some((d) => host === d.toLowerCase() || host.endsWith(`.${d.toLowerCase()}`));
}

/** The last two labels: enough for first- versus third-party between common hosts. */
function site(host: string): string {
  return host.split('.').slice(-2).join('.');
}

/** Chrome's urlFilter: `*` any run, `^` a separator or the end, `|` an anchor, `||` a domain anchor. */
function urlFilterMatches(filter: string, url: string, caseSensitive: boolean): boolean {
  let pattern = filter;
  let prefix = '';
  if (pattern.startsWith('||')) {
    pattern = pattern.slice(2);
    prefix = '^[a-z][a-z0-9+.-]*:\\/\\/(?:[^/?#]*\\.)?';
  } else if (pattern.startsWith('|')) {
    pattern = pattern.slice(1);
    prefix = '^';
  }
  const anchoredEnd = pattern.endsWith('|');
  if (anchoredEnd) pattern = pattern.slice(0, -1);
  const body = pattern.split('').map((ch) => {
    if (ch === '*') return '.*';
    if (ch === '^') return '(?:[^a-zA-Z0-9_.%-]|$)';
    return ch.replace(/[.+?${}()|[\]\\/]/g, '\\$&');
  }).join('');
  return new RegExp(prefix + body + (anchoredEnd ? '$' : ''), caseSensitive ? '' : 'i').test(url);
}

/** Whether `rule` applies to `request`, condition by condition, as Chrome evaluates them. */
export function ruleMatches(rule: Rule, request: TestRequest): boolean {
  const c = rule.condition ?? {};
  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return false;
  }
  const host = url.hostname.toLowerCase();
  const initiatorHost = request.initiator ? (() => { try { return new URL(request.initiator).hostname.toLowerCase(); } catch { return ''; } })() : '';
  if (c.responseHeaders || c.excludedResponseHeaders) return false;
  if (c.urlFilter !== undefined && !urlFilterMatches(c.urlFilter, request.url, c.isUrlFilterCaseSensitive === true)) return false;
  if (c.regexFilter !== undefined) {
    try {
      if (!new RegExp(c.regexFilter, c.isUrlFilterCaseSensitive === true ? '' : 'i').test(request.url)) return false;
    } catch {
      return false;
    }
  }
  if (c.requestDomains && !hostMatches(host, c.requestDomains)) return false;
  if (c.excludedRequestDomains && hostMatches(host, c.excludedRequestDomains)) return false;
  const initiatorDomains = c.initiatorDomains ?? c.domains;
  const excludedInitiatorDomains = c.excludedInitiatorDomains ?? c.excludedDomains;
  if (initiatorDomains && !(initiatorHost && hostMatches(initiatorHost, initiatorDomains))) return false;
  if (excludedInitiatorDomains && initiatorHost && hostMatches(initiatorHost, excludedInitiatorDomains)) return false;
  // Without resourceTypes, a rule matches every type but the main frame.
  if (c.resourceTypes ? !c.resourceTypes.includes(request.type) : request.type === 'main_frame') return false;
  if (c.excludedResourceTypes?.includes(request.type)) return false;
  const method = (request.method ?? 'get').toLowerCase();
  if (c.requestMethods && !c.requestMethods.includes(method)) return false;
  if (c.excludedRequestMethods?.includes(method)) return false;
  if (c.tabIds && !(request.tabId !== undefined && c.tabIds.includes(request.tabId))) return false;
  if (c.excludedTabIds && request.tabId !== undefined && c.excludedTabIds.includes(request.tabId)) return false;
  if (c.domainType) {
    const thirdParty = initiatorHost !== '' && site(initiatorHost) !== site(host);
    if ((c.domainType === 'thirdParty') !== thirdParty) return false;
  }
  return true;
}

/**
 * The rules that act on `request`: the winning one by priority, then action, then source; and the
 * modifyHeaders rules above an allow that wins, or all of them when none does.
 */
export function matchOutcome(sources: RuleSource[], request: TestRequest): { ruleId: number; rulesetId: string }[] {
  const order = [SESSION_RULESET_ID, DYNAMIC_RULESET_ID];
  const sourceRank = (id: string) => (order.includes(id) ? order.indexOf(id) : order.length);
  const matched = sources.flatMap((source) => source.rules
    .filter((rule) => ruleMatches(rule, request))
    .map((rule) => ({ rule, rulesetId: source.rulesetId })));
  const rank = (m: { rule: Rule; rulesetId: string }) => [-(m.rule.priority ?? 1), ACTION_ORDER.indexOf(m.rule.action.type), sourceRank(m.rulesetId)];
  const byPrecedence = (a: typeof matched[number], b: typeof matched[number]) => {
    const [ra, rb] = [rank(a), rank(b)];
    return ra[0] - rb[0] || ra[1] - rb[1] || ra[2] - rb[2];
  };
  const winner = matched.filter((m) => m.rule.action.type !== 'modifyHeaders').sort(byPrecedence)[0];
  const allows = winner && (winner.rule.action.type === 'allow' || winner.rule.action.type === 'allowAllRequests');
  const headers = winner?.rule.action.type === 'block' || winner?.rule.action.type === 'redirect' ? [] : matched
    .filter((m) => m.rule.action.type === 'modifyHeaders' && (!allows || (m.rule.priority ?? 1) > (winner.rule.priority ?? 1)))
    .sort(byPrecedence);
  return [...(winner ? [winner] : []), ...headers].map((m) => ({ ruleId: m.rule.id, rulesetId: m.rulesetId }));
}

/** The rules WebKit applies for this extension: its enabled static rulesets, dynamic and session rules. */
async function ruleSources(dnr: any): Promise<RuleSource[]> {
  const c = bridgeChrome();
  const resources: { id: string; path: string }[] = c.runtime.getManifest?.()?.declarative_net_request?.rule_resources ?? [];
  const enabled: string[] = await dnr.getEnabledRulesets();
  const staticSources = await Promise.all(resources
    .filter((resource) => enabled.includes(resource.id))
    .map(async (resource) => ({
      rulesetId: resource.id,
      rules: await fetch(c.runtime.getURL(resource.path)).then((r) => r.json()).catch(() => []) as Rule[],
    })));
  // WebKit applies a rule it can express; Lilo prepared the static rule files, inert rules included.
  const applied = (rule: Rule) => webKitRule(rule) !== undefined;
  return [
    { rulesetId: SESSION_RULESET_ID, rules: (await dnr.getSessionRules()).filter(applied) },
    { rulesetId: DYNAMIC_RULESET_ID, rules: (await dnr.getDynamicRules()).filter(applied) },
    ...staticSources.map((source) => ({ ...source, rules: fromWebKit(source.rules.filter((rule) => rule.condition?.regexFilter !== INERT_FILTER)) })),
  ];
}

/** Installed on `dnr` only for extensions holding declarativeNetRequestFeedback, as Chrome exposes it. */
export function testMatchOutcomeFor(dnr: any) {
  return function testMatchOutcome(request: TestRequest, callback?: (result: { matchedRules: unknown[] }) => void) {
    return callbackify(async () => ({ matchedRules: matchOutcome(await ruleSources(dnr), request) }), callback);
  };
}
