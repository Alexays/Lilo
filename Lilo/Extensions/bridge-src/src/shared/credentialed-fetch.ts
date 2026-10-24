// WebKit sends an extension's credentialed fetch to another site without its SameSite=Lax and Strict cookies, where
// Chrome sends every cookie to a host the extension may access (WEBKIT-GAPS.md, gap 81): such a fetch goes through
// Lilo, which answers null when the extension may not access the host. Redirect "manual" stays WebKit's. SW-safe.
import { gapCall } from './ipc.ts';

interface Answer {
  status: number;
  headers: [string, string][];
  body: string;
  url: string;
  redirected: boolean;
}

function base64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

// Statuses whose response has no body: Response throws when given one.
const bodiless = new Set([101, 103, 204, 205, 304]);

export function installCredentialedFetch(scope: any): void {
  const fetch = scope.fetch;
  if (typeof fetch !== 'function' || !scope.location) return;
  const origin = `${scope.location.protocol}//${scope.location.host}`;
  scope.fetch = function (input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const credentials = init?.credentials ?? (input instanceof Request ? input.credentials : undefined);
    if (credentials !== 'include') return fetch.call(scope, input, init);
    let request: Request;
    try {
      request = new Request(input, init);
    } catch {
      return fetch.call(scope, input, init);
    }
    const url = new URL(request.url);
    if (!['http:', 'https:'].includes(url.protocol) || url.origin === origin || request.redirect === 'manual') return fetch.call(scope, input, init);
    const signal = request.signal;
    return (async () => {
      if (signal.aborted) throw signal.reason ?? new DOMException('The operation was aborted.', 'AbortError');
      const body = request.method === 'GET' || request.method === 'HEAD' ? undefined : base64(new Uint8Array(await request.clone().arrayBuffer()));
      const headers: [string, string][] = [];
      request.headers.forEach((value, name) => headers.push([name, value]));
      if (!request.headers.has('user-agent')) headers.push(['User-Agent', scope.navigator?.userAgent ?? '']);
      const call = gapCall<Answer | null>('fetch', 'credentialed', { url: request.url, method: request.method, headers, body, redirect: request.redirect });
      const aborted = new Promise<never>((_, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason ?? new DOMException('The operation was aborted.', 'AbortError')), { once: true });
      });
      const answer = await Promise.race([call.catch((error) => { throw new TypeError(String(error?.message ?? 'Failed to fetch')); }), aborted]);
      // The request, not `input`: building it took a body stream `init` or `input` held.
      if (answer == null) return fetch.call(scope, request);
      const binary = atob(answer.body);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      const response = new Response(bodiless.has(answer.status) ? null : bytes, { status: answer.status, headers: answer.headers });
      Object.defineProperties(response, { url: { value: answer.url }, redirected: { value: answer.redirected } });
      return response;
    })();
  };
}
