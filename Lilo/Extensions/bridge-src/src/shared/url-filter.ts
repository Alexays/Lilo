// Chrome's events.UrlFilter, as listeners of filtered events (webNavigation) pass it.
//
// SW-safe: only URL and RegExp.

export interface UrlFilter {
  hostContains?: string;
  hostEquals?: string;
  hostPrefix?: string;
  hostSuffix?: string;
  pathContains?: string;
  pathEquals?: string;
  pathPrefix?: string;
  pathSuffix?: string;
  queryContains?: string;
  queryEquals?: string;
  queryPrefix?: string;
  querySuffix?: string;
  urlContains?: string;
  urlEquals?: string;
  urlMatches?: string;
  originAndPathMatches?: string;
  urlPrefix?: string;
  urlSuffix?: string;
  schemes?: string[];
  ports?: Array<number | [number, number]>;
}

const DEFAULT_PORTS: Record<string, number> = { 'http:': 80, 'https:': 443, 'ws:': 80, 'wss:': 443, 'ftp:': 21 };

type Part = 'host' | 'path' | 'query' | 'url';

function test(part: Part, filter: UrlFilter, value: string): boolean {
  const contains = filter[`${part}Contains` as keyof UrlFilter] as string | undefined;
  const equals = filter[`${part}Equals` as keyof UrlFilter] as string | undefined;
  const prefix = filter[`${part}Prefix` as keyof UrlFilter] as string | undefined;
  const suffix = filter[`${part}Suffix` as keyof UrlFilter] as string | undefined;
  return (contains === undefined || value.includes(contains))
    && (equals === undefined || value === equals)
    && (prefix === undefined || value.startsWith(prefix))
    && (suffix === undefined || value.endsWith(suffix));
}

/**
 * Chrome matches host criteria against the host with a leading dot, and adds one to an equals or prefix
 * criterion that lacks it: `hostContains: '.foo'` and `hostPrefix: 'foo'` both match `foo.com`.
 */
function compileUrlFilter(filter: UrlFilter): (url: URL) => boolean {
  const urlMatches = filter.urlMatches === undefined ? undefined : new RegExp(filter.urlMatches);
  const originAndPathMatches = filter.originAndPathMatches === undefined ? undefined : new RegExp(filter.originAndPathMatches);
  const { hostEquals, hostPrefix } = filter;
  const host: UrlFilter = {
    hostContains: filter.hostContains,
    hostEquals: hostEquals === undefined || hostEquals.startsWith('.') ? hostEquals : `.${hostEquals}`,
    hostPrefix: hostPrefix === undefined || hostPrefix.startsWith('.') ? hostPrefix : `.${hostPrefix}`,
    hostSuffix: filter.hostSuffix,
  };
  return (url) => {
    // Chrome matches the url* criteria against the URL without its fragment.
    const withoutFragment = url.href.split('#')[0];
    const port = url.port === '' ? DEFAULT_PORTS[url.protocol] : Number(url.port);
    if (filter.schemes && !filter.schemes.includes(url.protocol.slice(0, -1))) return false;
    if (filter.ports && !filter.ports.some((p) => (Array.isArray(p) ? port >= p[0] && port <= p[1] : port === p))) return false;
    if (urlMatches && !urlMatches.test(withoutFragment)) return false;
    if (originAndPathMatches && !originAndPathMatches.test(url.origin + url.pathname)) return false;
    return test('host', host, `.${url.hostname.toLowerCase()}`)
      && test('path', filter, url.pathname)
      && test('query', filter, url.search.replace(/^\?/, ''))
      && test('url', filter, withoutFragment);
  };
}

/**
 * A listener's `{ url: [...] }` filter, compiled once: it matches when any of its UrlFilters does, and undefined
 * (no filter) matches all. Throws on an invalid regular expression, as Chrome's addListener does.
 */
export function compileUrlFilters(filters: UrlFilter[] | undefined): ((url: URL) => boolean) | undefined {
  if (!filters || filters.length === 0) return undefined;
  const compiled = filters.map(compileUrlFilter);
  return (url) => compiled.some((matches) => matches(url));
}
