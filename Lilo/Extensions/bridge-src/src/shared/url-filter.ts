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

/** Whether `filter` matches `rawUrl`: every criterion it sets must hold. */
export function matchesUrlFilter(rawUrl: string, filter: UrlFilter): boolean {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    return false;
  }
  // Chrome matches the url* criteria against the URL without its fragment.
  const withoutFragment = url.href.split('#')[0];
  const port = url.port === '' ? DEFAULT_PORTS[url.protocol] : Number(url.port);
  if (filter.schemes && !filter.schemes.includes(url.protocol.slice(0, -1))) return false;
  if (filter.ports && !filter.ports.some((p) => (Array.isArray(p) ? port >= p[0] && port <= p[1] : port === p))) return false;
  if (filter.urlMatches !== undefined && !new RegExp(filter.urlMatches).test(withoutFragment)) return false;
  if (filter.originAndPathMatches !== undefined && !new RegExp(filter.originAndPathMatches).test(url.origin + url.pathname)) return false;
  return test('host', filter, url.hostname.toLowerCase())
    && test('path', filter, url.pathname)
    && test('query', filter, url.search.replace(/^\?/, ''))
    && test('url', filter, withoutFragment);
}

/** A listener's `{ url: [...] }` filter matches when any of its UrlFilters does; no filter matches all. */
export function matchesUrlFilters(rawUrl: string, filters: UrlFilter[] | undefined): boolean {
  return !filters || filters.length === 0 || filters.some((filter) => matchesUrlFilter(rawUrl, filter));
}
