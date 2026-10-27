// WebKit rejects some rules Chrome accepts, failing the whole update: each goes to WebKit in its closest accepted form,
// with the original stored beside it (WebKit keeps unknown keys) so get*Rules answer as Chrome. SW-safe: no window/document/webkit.
import { bridgeChrome, callbackify } from './callbackify.ts';
import type { Patch } from './chrome-compat.ts';
import { gapCall } from './ipc.ts';

const STORED_RULE = 'liloChromeRule';
export const INERT_FILTER = '^lilo-inert-rule:';
const MAX_REPEAT = 48;

// Outside a character class, and their bodies inside one.
const CLASSES: Record<string, string> = { d: '0-9', w: 'A-Za-z0-9_', s: '\\t\\n\\f\\r ' };
const POSIX: Record<string, string> = {
  alnum: '0-9A-Za-z', alpha: 'A-Za-z', blank: '\\t ', digit: '0-9', lower: 'a-z', upper: 'A-Z',
  space: '\\t\\n\\v\\f\\r ', word: '0-9A-Za-z_', xdigit: '0-9A-Fa-f', punct: '!-\\/:-@\\[-`{-~',
};

/** A parsed term: one atom (`single` when it matches one character) and its repetition. */
interface Term {
  text: string;
  single?: string;
  bol?: boolean;
  eol?: boolean;
  alternatives?: Term[][];
  capturing?: boolean;
  min: number;
  max: number;
}

class Unsupported extends Error {}
const fail = (): never => { throw new Unsupported(); };

/** RE2 syntax in WebKit's subset, or undefined when one regex cannot say the same. */
export function webKitRegex(source: string): string | undefined {
  if (!/^[\x20-\x7e]*$/.test(source)) return undefined;
  let i = 0;

  const escapeInClass = (c: string) => (/[\]\\^-]/.test(c) ? `\\${c}` : c);

  function classBody(): { body: string; negated: boolean } {
    let body = '';
    let negated = false;
    i++;
    if (source[i] === '^') { negated = true; i++; }
    let first = true;
    while (i < source.length && (source[i] !== ']' || first)) {
      first = false;
      if (source.startsWith('[:', i)) {
        const end = source.indexOf(':]', i);
        body += POSIX[source.slice(i + 2, end)] ?? fail();
        i = end + 2;
      } else if (source[i] === '\\') {
        const e = source[++i] ?? fail();
        i++;
        if (CLASSES[e]) body += CLASSES[e];
        else if (/[a-zA-Z0-9]/.test(e) && !'tnrfv'.includes(e)) fail();
        else body += `\\${e}`;
      } else if (source[i] === '[') {
        fail();
      } else {
        body += source[i++];
      }
    }
    if (source[i] !== ']') fail();
    i++;
    return { body, negated };
  }

  function atom(): Term {
    const c = source[i];
    const term = (fields: Partial<Term>): Term => ({ text: '', min: 1, max: 1, ...fields });
    if (c === '(') {
      i++;
      let capturing = true;
      if (source[i] === '?') {
        if (source[i + 1] === ':') i += 2;
        else if (source.startsWith('P<', i + 1) || (source[i + 1] === '<' && /[a-zA-Z]/.test(source[i + 2] ?? ''))) i = source.indexOf('>', i) + 1 || fail();
        else fail();
        capturing = source[i - 1] !== ':';
      }
      const alternatives = disjunction();
      if (source[i] !== ')') fail();
      i++;
      return term({ alternatives, capturing });
    }
    if (c === '[') {
      const { body, negated } = classBody();
      const text = `[${negated ? '^' : ''}${body}]`;
      return term({ text, single: negated ? undefined : body });
    }
    if (c === '\\') {
      const e = source[i + 1] ?? fail();
      i += 2;
      if (CLASSES[e]) return term({ text: `[${CLASSES[e]}]`, single: CLASSES[e] });
      if (CLASSES[e.toLowerCase()]) return term({ text: `[^${CLASSES[e.toLowerCase()]}]` });
      if (e === 'A') return term({ bol: true });
      if (e === 'z') return term({ eol: true });
      if (e === 'Q') {
        const end = source.indexOf('\\E', i);
        const literal = source.slice(i, end < 0 ? undefined : end);
        i = end < 0 ? source.length : end + 2;
        return term({ text: literal.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&') });
      }
      if (/[a-zA-Z0-9]/.test(e) && !'tnrfv'.includes(e)) fail();
      return term({ text: `\\${e}`, single: `\\${e}` });
    }
    i++;
    if (c === '^') return term({ bol: true });
    if (c === '$') return term({ eol: true });
    if (c === '.') return term({ text: '.', single: '.' });
    if ('*+?'.includes(c)) fail();
    const text = /[{}\]/]/.test(c) ? `\\${c}` : c;
    return term({ text, single: escapeInClass(c) });
  }

  function quantify(term: Term): void {
    const c = source[i];
    let range: [number, number] | undefined;
    if (c === '*') range = [0, Infinity];
    else if (c === '+') range = [1, Infinity];
    else if (c === '?') range = [0, 1];
    const counted = c === '{' ? /^\{(\d+)(,(\d*))?\}/.exec(source.slice(i)) : null;
    if (counted) range = [Number(counted[1]), counted[2] === undefined ? Number(counted[1]) : counted[3] ? Number(counted[3]) : Infinity];
    if (!range) return;
    if (term.bol || term.eol || range[0] > range[1]) fail();
    i += counted ? counted[0].length : 1;
    // A lazy quantifier matches the same URLs.
    if (source[i] === '?') i++;
    [term.min, term.max] = [term.min * range[0], term.max * range[1]];
  }

  function sequence(): Term[] {
    const terms: Term[] = [];
    while (i < source.length && source[i] !== '|' && source[i] !== ')') {
      const term = atom();
      quantify(term);
      terms.push(term);
    }
    return terms;
  }

  function disjunction(): Term[][] {
    const alternatives = [sequence()];
    while (source[i] === '|') {
      i++;
      alternatives.push(sequence());
    }
    return alternatives;
  }

  /** The alternatives as one sequence: a character class, or the one non-empty alternative made optional. */
  function oneOf(alternatives: Term[][], capturing: boolean, quantified = false): string {
    const group = (inner: string) => (capturing ? `(${inner})` : `(?:${inner})`);
    if (alternatives.length === 1) return group(emit(alternatives[0]));
    const filled = alternatives.filter((alternative) => alternative.length > 0);
    if (filled.length === 1 && !quantified) return `${group(emit(filled[0]))}?`;
    if (filled.length < alternatives.length) fail();
    const singles = alternatives.map((alternative) => (alternative.length === 1 && alternative[0].min === 1 && alternative[0].max === 1 ? alternative[0].single : undefined));
    if (singles.some((single) => single === undefined)) fail();
    const text = singles.includes('.') ? '.' : `[${singles.join('')}]`;
    return capturing ? `(${text})` : text;
  }

  function repeat(text: string, min: number, max: number): string {
    if (min === 1 && max === 1) return text;
    if (min === 0 && max === 1) return `${text}?`;
    if (min === 0 && max === Infinity) return `${text}*`;
    if (min === 1 && max === Infinity) return `${text}+`;
    // Copies of a capturing group would renumber the groups a regexSubstitution names.
    if (min > MAX_REPEAT || (max !== Infinity && max > MAX_REPEAT) || text.startsWith('(') && !text.startsWith('(?:')) fail();
    return text.repeat(min) + (max === Infinity ? `${text}*` : `${text}?`.repeat(max - min));
  }

  function emit(terms: Term[]): string {
    return terms.map((term) => {
      if (term.bol || term.eol) fail();
      const quantified = term.min !== 1 || term.max !== 1;
      const text = term.alternatives ? oneOf(term.alternatives, term.capturing!, quantified) : term.text;
      return repeat(text, term.min, term.max);
    }).join('');
  }

  try {
    const top = disjunction();
    if (i < source.length || top.length > 1) return undefined;
    const terms = top[0];
    let head = '';
    let tail = '';
    if (terms[0]?.bol) {
      head = '^';
      terms.shift();
    } else if (terms[0]?.alternatives && terms[0].min === 1 && terms[0].max === 1) {
      // `(^|X)P` is P at the start or after X: `^(?:.*X)?P`.
      const { alternatives, capturing } = terms[0];
      const others = alternatives.filter((alternative) => !(alternative.length === 1 && alternative[0].bol && alternative[0].min === 1));
      if (others.length === alternatives.length - 1 && others.length > 0) {
        head = `^(?:.*${oneOf(others, capturing!)})?`;
        terms.shift();
      }
    }
    const last = terms[terms.length - 1];
    if (last?.eol && last.min === 1) {
      tail = '$';
      terms.pop();
    } else if (last?.alternatives && last.min === 1 && last.max === 1) {
      // `P(X|$)` is P followed by X or by the end: `P(?:X.*)?$`.
      const { alternatives, capturing } = last;
      const others = alternatives.filter((alternative) => !(alternative.length === 1 && alternative[0].eol && alternative[0].min === 1));
      if (others.length === alternatives.length - 1 && others.length > 0) {
        tail = `(?:${oneOf(others, capturing!)}.*)?$`;
        terms.pop();
      }
    }
    return head + emit(terms) + tail;
  } catch (error) {
    if (error instanceof Unsupported) return undefined;
    throw error;
  }
}

// The request and response headers WebKit's declarativeNetRequest modifies.
const WEBKIT_HEADERS = new Set(('accept accept-charset accept-language accept-encoding accept-ranges access-control-allow-credentials ' +
  'access-control-allow-headers access-control-allow-methods access-control-allow-origin access-control-expose-headers ' +
  'access-control-max-age access-control-request-headers access-control-request-method age authorization cache-control ' +
  'connection content-disposition content-encoding content-language content-length content-location content-security-policy ' +
  'content-security-policy-report-only content-type content-range cookie cookie2 cross-origin-embedder-policy ' +
  'cross-origin-embedder-policy-report-only cross-origin-opener-policy cross-origin-opener-policy-report-only ' +
  'cross-origin-resource-policy date dnt default-style etag expect expires host if-match if-modified-since if-none-match ' +
  'if-range if-unmodified-since keep-alive last-event-id last-modified link location origin ping-from ping-to purpose ' +
  'pragma proxy-authorization range referer referrer-policy refresh report-to reporting-endpoints sec-fetch-dest ' +
  'sec-fetch-mode sec-gpc sec-websocket-accept sec-websocket-extensions sec-websocket-key sec-websocket-protocol ' +
  'sec-websocket-version server-timing service-worker service-worker-allowed service-worker-navigation-preload set-cookie ' +
  'set-cookie2 sourcemap te timing-allow-origin trailer transfer-encoding upgrade upgrade-insecure-requests user-agent vary ' +
  'via x-content-type-options x-frame-options x-sourcemap x-xss-protection x-temp-tablet icy-metaint icy-metadata').split(' '));

// Resource types Chrome knows and WebKit rejects in `resourceTypes`: it never loads such a request.
const NON_WEBKIT_TYPES = new Set(['object', 'csp_report', 'webtransport', 'webbundle']);
// Chrome takes them empty, excluding nothing; WebKit rejects the rule or fails to compile the whole update.
const EXCLUSIONS = ['excludedInitiatorDomains', 'excludedDomains', 'excludedRequestMethods'];

function isRegExp(source: string): boolean {
  try {
    new RegExp(source);
    return true;
  } catch {
    return false;
  }
}

/** The extension's own origins: WebKit's, and the chrome-extension:// one extensions build by hand. */
function ownOrigins(): string[] {
  const runtime = bridgeChrome()?.runtime;
  return [runtime?.getURL?.('/'), runtime?.id && `chrome-extension://${runtime.id}/`].filter(Boolean);
}

/**
 * `rule` in a form WebKit applies the same way (itself if WebKit takes it), or undefined when WebKit cannot apply
 * it. A rule Chrome rejects too is returned as it is, for WebKit to reject.
 */
export function webKitRule(rule: any): any {
  if (rule === null || typeof rule !== 'object') return rule;
  let result = rule;
  const regexFilter = rule.condition?.regexFilter;
  if (typeof regexFilter === 'string' && isRegExp(regexFilter)) {
    const regex = webKitRegex(regexFilter);
    if (regex === undefined) return undefined;
    if (regex !== regexFilter) result = { ...result, condition: { ...result.condition, regexFilter: regex } };
  }
  const types = rule.condition?.resourceTypes;
  if (Array.isArray(types) && types.some((type) => NON_WEBKIT_TYPES.has(type))) {
    const resourceTypes = types.filter((type) => !NON_WEBKIT_TYPES.has(type));
    if (!resourceTypes.length) return undefined;
    result = { ...result, condition: { ...result.condition, resourceTypes } };
  }
  const empty = EXCLUSIONS.filter((key) => Array.isArray(rule.condition?.[key]) && !rule.condition[key].length);
  if (empty.length) {
    const condition = { ...result.condition };
    for (const key of empty) delete condition[key];
    result = { ...result, condition };
  }
  const redirect = rule.action?.redirect;
  // A scheme test, not URL.canParse: static rulesets are prepared in a bare JavaScriptCore context, which has no URL.
  if (rule.action?.type === 'redirect' && typeof redirect?.url === 'string' && !/^(https?|javascript):/i.test(redirect.url) && /^[a-z][a-z\d+.-]*:/i.test(redirect.url)) {
    const origin = ownOrigins().find((base) => redirect.url.startsWith(base));
    if (!origin) return undefined;
    const { url: _url, ...rest } = redirect;
    result = { ...result, action: { ...result.action, redirect: { ...rest, extensionPath: redirect.url.slice(origin.length - 1) } } };
  }
  if (rule.action?.type === 'modifyHeaders') {
    const known = (headers: any): any => Array.isArray(headers)
      ? headers.filter((info) => typeof info?.header !== 'string' || WEBKIT_HEADERS.has(info.header.toLowerCase()))
      : headers;
    const requestHeaders = known(rule.action.requestHeaders);
    const responseHeaders = known(rule.action.responseHeaders);
    if (requestHeaders?.length !== rule.action.requestHeaders?.length || responseHeaders?.length !== rule.action.responseHeaders?.length) {
      if (!requestHeaders?.length && !responseHeaders?.length) return undefined;
      const action = { ...result.action, requestHeaders, responseHeaders };
      if (!requestHeaders?.length) delete action.requestHeaders;
      if (!responseHeaders?.length) delete action.responseHeaders;
      result = { ...result, action };
    }
  }
  return result;
}

function toWebKit(rule: any): any {
  const applied = webKitRule(rule);
  if (applied === rule) return rule;
  const stored = applied ?? { id: rule.id, action: { type: 'block' }, condition: { regexFilter: INERT_FILTER } };
  return { ...stored, [STORED_RULE]: rule };
}

export const fromWebKit = (rules: any) => (Array.isArray(rules) ? rules.map((rule) => rule?.[STORED_RULE] ?? rule) : rules);

// WebKit compiles an extension's rules into at most 150000 content blocker rules, one per request
// domain and per excluded request domain of each rule. Static rules leave room for 30000 dynamic ones.
const STATIC_WEBKIT_RULES = 150000 - 30000;

/**
 * Each static ruleset as JSON in the form WebKit applies, or null where it needs no change or is no ruleset. Past
 * WebKit's cap for all of them together, the rules WebKit expands most turn inert, and once that is not enough, rules
 * leave the sets: inert ones first, then blocking ones before the ones that let requests through, the last of a file first.
 */
export function webKitStaticRulesets(sources: string[]): (string | null)[] {
  const rulesets = sources.map((source) => {
    try {
      const rules = JSON.parse(source.replace(/^\uFEFF/, ''));
      return Array.isArray(rules) ? rules : undefined;
    } catch {
      return undefined;
    }
  });
  const prepared: (any[] | undefined)[] = rulesets.map((rules) => rules?.map((rule) => toWebKit(rule?.[STORED_RULE] ?? rule)));
  const expansions = prepared.flatMap((rules, set) => (rules ?? []).map((rule, index) => {
    const condition = rule?.condition ?? {};
    const domains = typeof condition.regexFilter !== 'string' && Array.isArray(condition.requestDomains) ? condition.requestDomains.length : 1;
    const count = domains + (Array.isArray(condition.excludedRequestDomains) ? condition.excludedRequestDomains.length : 0);
    const blocking = rule?.action?.type === 'block' || rule?.action?.type === 'redirect';
    const rank = count > 1 ? count + 1 : condition.regexFilter === INERT_FILTER ? 1.5 : blocking ? 1.25 : 1;
    return { set, index, count, rank };
  }));
  let total = expansions.reduce((sum, { count }) => sum + count, 0);
  if (total > STATIC_WEBKIT_RULES) {
    expansions.sort((a, b) => b.rank - a.rank || b.index - a.index);
    for (const { set, index, count } of expansions) {
      if (total <= STATIC_WEBKIT_RULES) break;
      const rule = prepared[set]![index];
      // An inert rule still counts as one, and keeps the extension's own for testMatch and getDisabledRuleIds.
      prepared[set]![index] = count > 1
        ? { id: rule.id, action: { type: 'block' }, condition: { regexFilter: INERT_FILTER }, [STORED_RULE]: rule[STORED_RULE] ?? rule }
        : undefined;
      total -= count > 1 ? count - 1 : 1;
    }
    for (const [set, rules] of prepared.entries()) prepared[set] = rules?.filter((rule) => rule !== undefined);
  }
  return prepared.map((rules, set) => (rules && (rules.length !== rulesets[set]!.length || rules.some((rule, index) => rule !== rulesets[set]![index])) ? JSON.stringify(rules) : null));
}

// WebKit removes only the rule ids its last applied update left, and loads concurrent updates over
// each other: updates run one after the other, as in Chrome.
let lastUpdate: Promise<unknown> = Promise.resolve();
function queued<T>(update: () => Promise<T>): Promise<T> {
  const run = lastUpdate.then(update, update);
  lastUpdate = run.catch(() => {});
  return run;
}

interface PendingUpdate { options: any; resolve: (result: unknown) => void; reject: (error: unknown) => void }

/** Whether two JSON values are the same, whatever the order of their keys (WebKit stores rules as dictionaries). */
function sameJSON(a: any, b: any): boolean {
  if (a === b) return true;
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null || Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((key) => Object.hasOwn(b, key) && sameJSON(a[key], b[key]));
}

// WebKit recompiles all of the extension's rules on each update, so the calls made before one starts
// go to WebKit as a single update, and an update that changes nothing is not sent.
const updateRules = (getRules: string): Patch => (original, self) => {
  let batch: PendingUpdate[] | undefined;
  return function (this: unknown, options: any, callback?: () => void) {
    const namespace: any = self(this);
    return callbackify(() => new Promise((resolve, reject) => {
      if (batch) {
        batch.push({ options, resolve, reject });
        return;
      }
      const calls = [{ options, resolve, reject }];
      batch = calls;
      queued(async () => {
        batch = undefined;
        // One update applying the calls in order; an id added twice without a removal between, or options
        // only WebKit can judge, send the calls one at a time instead.
        const removed = new Set<number>();
        const added = new Map<number, any>();
        const mergeable = calls.every(({ options }) => {
          if (typeof options !== 'object' || options === null) return false;
          const { removeRuleIds = [], addRules = [], ...rest } = options;
          if (Object.keys(rest).length || !Array.isArray(removeRuleIds) || !Array.isArray(addRules) || !removeRuleIds.every(Number.isInteger)) return false;
          for (const id of removeRuleIds) {
            removed.add(id);
            added.delete(id);
          }
          for (const rule of addRules) {
            if (!Number.isInteger(rule?.id) || added.has(rule.id)) return false;
            added.set(rule.id, rule);
          }
          return true;
        });
        if (mergeable) {
          try {
            let result: unknown;
            // A rule removed and added back as it is stays: WebKit would delete its rules database once the removals
            // empty it and recompile every rule, which extensions replacing all their rules at each start would pay.
            const current = new Map<number, any>(removed.size ? (await namespace[getRules]()).map((rule: any) => [rule?.id, rule]) : []);
            const addRules: any[] = [];
            for (const [id, rule] of added) {
              if (removed.has(id) && sameJSON(current.get(id), rule)) removed.delete(id);
              else addRules.push(toWebKit(rule));
            }
            if (addRules.length || [...removed].some((id) => current.has(id))) {
              result = await original.call(namespace, { removeRuleIds: [...removed], addRules });
            }
            for (const call of calls) call.resolve(result);
            return;
          } catch (error) {
            if (calls.length === 1) {
              calls[0].reject(error);
              return;
            }
            // A failed update applies nothing: each call runs alone, for its own error to reach it.
          }
        }
        for (const call of calls) {
          const { options } = call;
          const translated = Array.isArray(options?.addRules) ? { ...options, addRules: options.addRules.map(toWebKit) } : options;
          try {
            call.resolve(await original.call(namespace, translated));
          } catch (error) {
            call.reject(error);
          }
        }
      });
    }), callback);
  };
};

const getRules: Patch = (original, self) => function (this: unknown, filter?: any, callback?: (rules: unknown[]) => void) {
  if (typeof filter === 'function') [filter, callback] = [undefined, filter];
  return callbackify(async () => fromWebKit(await original.call(self(this), ...(filter === undefined ? [] : [filter]))), callback);
};

export const declarativeNetRequestPatches: Record<string, Patch> = {
  updateDynamicRules: updateRules('getDynamicRules'),
  updateSessionRules: updateRules('getSessionRules'),
  getDynamicRules: getRules,
  getSessionRules: getRules,
  // WebKit counts each id against the 50 enabled rulesets, also one already as asked, and a count
  // below zero wraps around: it gets only the rulesets that change.
  updateEnabledRulesets: (original, self) => function (this: unknown, options: any, callback?: () => void) {
    const namespace: any = self(this);
    return callbackify(() => queued(async () => {
      const { enableRulesetIds: enable, disableRulesetIds: disable } = options ?? {};
      if (!(enable === undefined || Array.isArray(enable)) || !(disable === undefined || Array.isArray(disable))) return original.call(namespace, options);
      const resources = bridgeChrome()?.runtime?.getManifest?.()?.declarative_net_request?.rule_resources;
      const declared = new Set(Array.isArray(resources) ? resources.map((resource) => resource?.id) : []);
      const enabled = new Set(await namespace.getEnabledRulesets());
      const request: { disableRulesetIds: unknown[]; enableRulesetIds: unknown[] } = {
        ...options,
        disableRulesetIds: [...new Set(disable)].filter((id) => !declared.has(id) || (enabled.has(id) && !enable?.includes(id))),
        enableRulesetIds: [...new Set(enable)].filter((id) => !declared.has(id) || !enabled.has(id)),
      };
      const none = !request.enableRulesetIds.length && request.disableRulesetIds.filter((id) => enabled.has(id)).length === enabled.size;
      // Left with no rule, WebKit deletes its compiled rules, and fails while their first compile has not
      // written them yet: the update waits for that compile.
      for (const deadline = Date.now() + 60000; ;) {
        try {
          return await original.call(namespace, request);
        } catch (error) {
          if (!none || Date.now() > deadline || !/Failed to apply rules\.$/.test((error as Error)?.message)) throw error;
          const [dynamic, session] = await Promise.all([namespace.getDynamicRules(), namespace.getSessionRules()]);
          if (dynamic.length || session.length) throw error;
          await new Promise((resolve) => setTimeout(resolve, 250));
        }
      }
    }), callback);
  },
  // Chrome's functions work detached, as DuckDuckGo calls this one.
  isRegexSupported: (original, self) => function (this: unknown, options: any, callback?: (result: unknown) => void) {
    return callbackify(async () => {
      if (typeof options?.regex !== 'string') return original.call(self(this), options);
      const regex = isRegExp(options.regex) ? webKitRegex(options.regex) : undefined;
      if (regex === undefined) return { isSupported: false, reason: 'syntaxError' };
      return original.call(self(this), { ...options, regex });
    }, callback);
  },
};

/**
 * Chrome's disabled static rules, which WebKit lacks: native turns them inert in their ruleset's file. WebKit reads
 * the file each time it compiles the extension's rules, which turning the ruleset off and on in one update does.
 */
export const staticRulesAdditions = {
  getDisabledRuleIds(options: { rulesetId: string }, callback?: (ids: number[]) => void) {
    return callbackify(() => gapCall<number[]>('declarativeNetRequest', 'getDisabledRuleIds', { rulesetId: options?.rulesetId }), callback);
  },
  updateStaticRules(options: { rulesetId: string; disableRuleIds?: number[]; enableRuleIds?: number[] }, callback?: () => void) {
    return callbackify(() => queued(async () => {
      const { rulesetId, disableRuleIds = [], enableRuleIds = [] } = options ?? {};
      if (!await gapCall<boolean>('declarativeNetRequest', 'updateStaticRules', { rulesetId, disableRuleIds, enableRuleIds })) return;
      const dnr = bridgeChrome().declarativeNetRequest;
      if (!(await dnr.getEnabledRulesets()).includes(rulesetId)) return;
      await (dnr.updateEnabledRulesets.__liloUnwrapped ?? dnr.updateEnabledRulesets).call(dnr, { disableRulesetIds: [rulesetId], enableRulesetIds: [rulesetId] });
    }), callback);
  },
};
