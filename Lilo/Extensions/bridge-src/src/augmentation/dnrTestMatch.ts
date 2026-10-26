// WebKit applies the extension's rules but exposes no matcher, so this re-evaluates them with Chrome's matching and
// precedence; response-header conditions never match. SW-safe: chrome.*, gap calls and fetch only.
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { INERT_FILTER, fromWebKit, webKitRule } from '../shared/dnr-rules.ts';
import { gapCall } from '../shared/ipc.ts';

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
function urlFilterRegExp(filter: string, flags: string): RegExp {
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
  return new RegExp(prefix + body + (anchoredEnd ? '$' : ''), flags);
}

/** A rule's urlFilter and regexFilter, compiled; null for a regexFilter that never matches, being invalid. */
interface CompiledFilters {
  urlFilter?: RegExp;
  regexFilter?: RegExp | null;
}

const compiledFilters = new WeakMap<Rule, CompiledFilters>();

function filtersOf(rule: Rule): CompiledFilters {
  let filters = compiledFilters.get(rule);
  if (filters) return filters;
  const c = rule.condition ?? {};
  const flags = c.isUrlFilterCaseSensitive === true ? '' : 'i';
  filters = {};
  if (c.urlFilter !== undefined) filters.urlFilter = urlFilterRegExp(c.urlFilter, flags);
  if (c.regexFilter !== undefined) {
    try {
      filters.regexFilter = new RegExp(c.regexFilter, flags);
    } catch {
      filters.regexFilter = null;
    }
  }
  compiledFilters.set(rule, filters);
  return filters;
}

/** The request's host and initiator host, lowercased ('' without an initiator); undefined for an invalid url. */
interface RequestHosts {
  host: string;
  initiatorHost: string;
}

function hostsOf(request: TestRequest): RequestHosts | undefined {
  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return undefined;
  }
  const initiatorHost = request.initiator ? (() => { try { return new URL(request.initiator).hostname.toLowerCase(); } catch { return ''; } })() : '';
  return { host: url.hostname.toLowerCase(), initiatorHost };
}

/** Whether `rule` applies to `request`, condition by condition, as Chrome evaluates them, the regexes last. */
export function ruleMatches(rule: Rule, request: TestRequest, hosts = hostsOf(request)): boolean {
  if (!hosts) return false;
  const { host, initiatorHost } = hosts;
  const c = rule.condition ?? {};
  if (c.responseHeaders || c.excludedResponseHeaders) return false;
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
  if (c.urlFilter === undefined && c.regexFilter === undefined) return true;
  const filters = filtersOf(rule);
  if (filters.urlFilter && !filters.urlFilter.test(request.url)) return false;
  return filters.regexFilter === undefined || (filters.regexFilter !== null && filters.regexFilter.test(request.url));
}

/**
 * The rules that act on `request`: the winning one by priority, then action, then source; and the
 * modifyHeaders rules above an allow that wins, or all of them when none does.
 */
export function matchOutcome(sources: RuleSource[], request: TestRequest): { ruleId: number; rulesetId: string }[] {
  const order = [SESSION_RULESET_ID, DYNAMIC_RULESET_ID];
  const sourceRank = (id: string) => (order.includes(id) ? order.indexOf(id) : order.length);
  const hosts = hostsOf(request);
  if (!hosts) return [];
  const matched = sources.flatMap((source) => source.rules
    .filter((rule) => ruleMatches(rule, request, hosts))
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

/** The parsed static rules, for the enabled rulesets and disabled rule ids `key` names. */
let staticCache: { key: string; sources: Promise<RuleSource[]> } | undefined;

/** The rules WebKit applies for this extension: its enabled static rulesets, dynamic and session rules. */
async function ruleSources(dnr: any): Promise<RuleSource[]> {
  const c = bridgeChrome();
  const resources: { id: string; path: string }[] = c.runtime.getManifest?.()?.declarative_net_request?.rule_resources ?? [];
  const [enabled, session, dynamic, disabled]: [string[], Rule[], Rule[], number[][]] = await Promise.all([
    dnr.getEnabledRulesets(),
    dnr.getSessionRules(),
    dnr.getDynamicRules(),
    Promise.all(resources.map((resource) => gapCall<number[]>('declarativeNetRequest', 'getDisabledRuleIds', { rulesetId: resource.id }))),
  ]);
  // Disabling static rules rewrites their ruleset's file (inert rules), so the file follows the disabled ids too.
  const key = JSON.stringify(resources.map((resource, i) => (enabled.includes(resource.id) ? disabled[i] : null)));
  if (staticCache?.key !== key) {
    staticCache = {
      key,
      sources: Promise.all(resources
        .filter((resource) => enabled.includes(resource.id))
        .map(async (resource) => {
          const rules = await fetch(c.runtime.getURL(resource.path)).then((r) => r.json()).catch(() => {
            staticCache = undefined;
            return [];
          }) as Rule[];
          return { rulesetId: resource.id, rules: fromWebKit(rules.filter((rule) => rule.condition?.regexFilter !== INERT_FILTER)) };
        })),
    };
  }
  // WebKit applies a rule it can express; Lilo prepared the static rule files, inert rules included.
  const applied = (rule: Rule) => webKitRule(rule) !== undefined;
  return [
    { rulesetId: SESSION_RULESET_ID, rules: session.filter(applied) },
    { rulesetId: DYNAMIC_RULESET_ID, rules: dynamic.filter(applied) },
    ...await staticCache.sources,
  ];
}

/** Installed on `dnr` only for extensions holding declarativeNetRequestFeedback, as Chrome exposes it. */
export function testMatchOutcomeFor(dnr: any) {
  return function testMatchOutcome(request: TestRequest, callback?: (result: { matchedRules: unknown[] }) => void) {
    return callbackify(async () => ({ matchedRules: matchOutcome(await ruleSources(dnr), request) }), callback);
  };
}
