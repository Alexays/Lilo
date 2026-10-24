// The native preparer writes the list only for extensions declaring the permission: workers get it as
// `__liloPublicSuffixList`, pages read `_lilo/public-suffix-list.dat`. SW-safe: XMLHttpRequest runs only in pages.
import { bridgeChrome } from '../shared/callbackify.ts';

interface DomainOptions {
  encoding?: 'punycode' | 'display';
  allowIPAddress?: boolean;
  allowPlainSuffix?: boolean;
  allowUnknownSuffix?: boolean;
}

interface Hostname {
  /** Lowercase punycode labels, without the trailing dot. */
  labels: string[];
  trailingDot: string;
  ip?: string;
}

let rules: Set<string> | undefined;

function ruleSet(): Set<string> {
  if (rules) return rules;
  const g = globalThis as any;
  let text = g.__liloPublicSuffixList;
  if (typeof text !== 'string') {
    const request = new XMLHttpRequest();
    request.open('GET', bridgeChrome().runtime.getURL('_lilo/public-suffix-list.dat'), false);
    request.send();
    text = request.status === 200 || request.status === 0 ? request.responseText : '';
  }
  rules = new Set((text as string).split('\n').filter((line) => line && !line.startsWith('//')));
  return rules;
}

// Chrome's binding throws these for a call its schema or hostname check rejects.
function invocationError(method: string, detail: string): never {
  const signature = method === 'getDomain' ? 'string hostname, optional publicSuffix.DomainOptions options' : 'string hostname';
  throw new TypeError(`Error in invocation of publicSuffix.${method}(${signature}): ${detail}`);
}

/** The host canonicalized as a URL host is; throws what Chrome throws for one it rejects. */
function parse(input: unknown, method: string): Hostname {
  if (typeof input !== 'string') invocationError(method, 'No matching signature.');
  const invalid: () => never = () => invocationError(method, 'Invalid hostname');
  // "%2e" would canonicalize to a dot; ports, paths, credentials and schemes are not hostnames.
  if (!input || /[%/\\:@?#\s]/.test(input.startsWith('[') ? input.replace(/^\[[0-9a-fA-F:.]*\]$/, '') : input)) invalid();
  let host: string;
  try {
    host = new URL(`http://${input}`).hostname;
  } catch {
    invalid();
  }
  if (host.startsWith('[')) return { labels: [], trailingDot: '', ip: host };
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) return { labels: [], trailingDot: '', ip: host };
  const trailingDot = host.endsWith('.') ? '.' : '';
  const labels = (trailingDot ? host.slice(0, -1) : host).split('.');
  // net::IsCanonicalizedHostCompliant: non-empty labels of [a-z0-9-_], the last one starting alphanumeric.
  if (host.length > 254 || labels.some((label) => !/^[a-z0-9_-]{1,63}$/.test(label)) || !/^[a-z0-9]/.test(labels[labels.length - 1])) {
    invalid();
  }
  return { labels, trailingDot };
}

/** Index of the first label of the longest matching suffix, exceptions first; -1 when none matches. */
function suffixStart(labels: string[]): number {
  const set = ruleSet();
  for (let i = 0; i < labels.length; i++) {
    const candidate = labels.slice(i).join('.');
    if (set.has(`!${candidate}`)) return i + 1;
    if (set.has(candidate) || set.has(`*.${candidate}`)) return i;
    if (i + 1 < labels.length && set.has(`*.${labels.slice(i + 1).join('.')}`)) return i;
  }
  return -1;
}

function knownSuffix(host: Hostname): string | null {
  if (host.ip) return null;
  const start = suffixStart(host.labels);
  return start < 0 ? null : host.labels.slice(start).join('.') + host.trailingDot;
}

// Bootstring parameters of RFC 3492.
function decodePunycode(input: string): string {
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  const output: number[] = [];
  const delimiter = input.lastIndexOf('-');
  for (let j = 0; j < Math.max(delimiter, 0); j++) output.push(input.charCodeAt(j));
  let n = 128, bias = 72, i = 0;
  for (let index = delimiter + 1; index < input.length;) {
    const oldI = i;
    for (let w = 1, k = base; ; k += base) {
      if (index >= input.length) throw new RangeError('punycode');
      const code = input.charCodeAt(index++);
      const digit = code - 48 >>> 0 < 10 ? code - 22 : code - 97 >>> 0 < 26 ? code - 97 : base;
      if (digit >= base) throw new RangeError('punycode');
      i += digit * w;
      const t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias;
      if (digit < t) break;
      w *= base - t;
    }
    const length = output.length + 1;
    let delta = oldI === 0 ? Math.floor((i - oldI) / damp) : (i - oldI) >> 1;
    delta += Math.floor(delta / length);
    let k = 0;
    for (; delta > ((base - tMin) * tMax) >> 1; k += base) delta = Math.floor(delta / (base - tMin));
    bias = Math.floor(k + ((base - tMin + 1) * delta) / (delta + skew));
    n += Math.floor(i / length);
    i %= length;
    output.splice(i++, 0, n);
  }
  return String.fromCodePoint(...output);
}

const SCRIPTS = ['Latin', 'Cyrillic', 'Greek', 'Armenian', 'Georgian', 'Hebrew', 'Arabic', 'Thai', 'Devanagari', 'Bengali', 'Tamil', 'Hangul', 'Han', 'Hiragana', 'Katakana']
  .map((script) => [script, new RegExp(`\\p{Script=${script}}`, 'u')] as const);
// The script mixes Chrome's spoof checker allows in one label (Unicode's highly restrictive level).
const ALLOWED_MIXES = [new Set(['Latin', 'Han', 'Hiragana', 'Katakana']), new Set(['Latin', 'Han', 'Hangul'])];
// Cyrillic letters that read as Latin ones: a label made only of them spoofs a Latin name.
const LATIN_LOOKALIKE_CYRILLIC = /^[асԁеһіјӏорԛѕԝхуъьҽпгѵѡ\d-]+$/u;

/** A simplified IDN spoof check: a label shows as Unicode when it uses one script and is no whole-script lookalike. */
function displayLabel(label: string): string {
  if (!label.startsWith('xn--')) return label;
  let unicode: string;
  try {
    unicode = decodePunycode(label.slice(4));
  } catch {
    return label;
  }
  const scripts = new Set<string>();
  for (const char of unicode) {
    if (/[\d_-]/.test(char)) continue;
    const script = SCRIPTS.find(([, pattern]) => pattern.test(char))?.[0];
    if (!script) return label;
    scripts.add(script);
  }
  const mixed = scripts.size > 1 && !ALLOWED_MIXES.some((allowed) => [...scripts].every((script) => allowed.has(script)));
  if (mixed || (scripts.has('Cyrillic') && LATIN_LOOKALIKE_CYRILLIC.test(unicode))) return label;
  return unicode;
}

function encode(domain: string, options: DomainOptions): string {
  return options.encoding === 'display' ? domain.split('.').map(displayLabel).join('.') : domain;
}

export const publicSuffixAugmentation = {
  isKnownSuffix(hostname: string): boolean {
    const host = parse(hostname, 'isKnownSuffix');
    return !host.ip && suffixStart(host.labels) === 0;
  },

  getKnownSuffix(hostname: string): string | null {
    return knownSuffix(parse(hostname, 'getKnownSuffix'));
  },

  getDomain(hostname: string, options: DomainOptions = {}): string | null {
    const host = parse(hostname, 'getDomain');
    options ??= {};
    if (host.ip) return options.allowIPAddress ? host.ip : null;
    const name = host.labels.join('.') + host.trailingDot;
    const start = suffixStart(host.labels);
    if (start === 0) return options.allowPlainSuffix ? encode(name, options) : null;
    if (start > 0) return encode(host.labels.slice(start - 1).join('.') + host.trailingDot, options);
    if (!options.allowUnknownSuffix) return null;
    // An unknown TLD acts as the suffix: the registrable domain is its last two labels.
    return encode(host.labels.slice(-2).join('.') + host.trailingDot, options);
  },
};
