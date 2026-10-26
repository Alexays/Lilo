// WebKit sends an extension's credentialed fetch or XMLHttpRequest to another site without its SameSite=Lax and Strict
// cookies, where Chrome sends every cookie to a host the extension may access (WEBKIT-GAPS.md, gap 81): such a request
// goes through Lilo, which answers null when the extension may not access the host. Redirect "manual" stays WebKit's.
// SW-safe: the worker has no XMLHttpRequest.
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

/** Lilo's response to `request`, null for a host the extension may not access. Rejects as fetch does. */
async function sendThroughLilo(scope: any, request: Request): Promise<Response | null> {
  const signal = request.signal;
  if (signal.aborted) throw signal.reason ?? new DOMException('The operation was aborted.', 'AbortError');
  const body = request.method === 'GET' || request.method === 'HEAD' ? undefined : base64(new Uint8Array(await request.clone().arrayBuffer()));
  const headers: [string, string][] = [];
  request.headers.forEach((value, name) => headers.push([name, value]));
  if (!request.headers.has('user-agent')) headers.push(['User-Agent', scope.navigator?.userAgent ?? '']);
  // No timeout: a long poll or a large download takes as long as it takes, as in Chrome.
  const call = gapCall<Answer | null>('fetch', 'credentialed', { url: request.url, method: request.method, headers, body, redirect: request.redirect }, 0);
  let onAbort = (): void => {};
  const aborted = new Promise<never>((_, reject) => {
    onAbort = () => reject(signal.reason ?? new DOMException('The operation was aborted.', 'AbortError'));
    signal.addEventListener('abort', onAbort, { once: true });
  });
  let answer: Answer | null;
  try {
    answer = await Promise.race([call.catch((error) => { throw new TypeError(String(error?.message ?? 'Failed to fetch')); }), aborted]);
  } finally {
    signal.removeEventListener('abort', onAbort);
  }
  if (answer == null) return null;
  const binary = atob(answer.body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const response = new Response(bodiless.has(answer.status) ? null : bytes, { status: answer.status, headers: answer.headers });
  Object.defineProperties(response, { url: { value: answer.url }, redirected: { value: answer.redirected } });
  return response;
}

// What Lilo's response shows through: own properties over the prototype's getters, which open() clears.
const shown = ['readyState', 'status', 'statusText', 'responseURL', 'response', 'responseText', 'responseXML', 'getResponseHeader', 'getAllResponseHeaders'];

interface Opened {
  method: string;
  url: string;
  routed: boolean;
  headers: [string, string][];
  phase: 'opened' | 'sent' | 'done';
  controller?: AbortController;
  timedOut?: boolean;
}

/**
 * An asynchronous XMLHttpRequest with `withCredentials` to another site goes through Lilo, its states and events
 * dispatched on the request itself; a synchronous one, one with a user or password, or one for a `document` stays
 * WebKit's, as does one to a host the extension may not access. `upload` fires no event.
 */
function routeCredentialedXHR(scope: any, origin: string): void {
  const proto = scope.XMLHttpRequest.prototype;
  const { open, send, setRequestHeader, abort } = proto;
  const requests = new WeakMap<object, Opened>();
  const show = (xhr: object, values: Record<string, unknown>) => {
    for (const key in values) Object.defineProperty(xhr, key, { value: values[key], configurable: true });
  };
  const fire = (xhr: any, type: string, loaded = 0, lengthComputable = false) => {
    xhr.dispatchEvent(type === 'readystatechange' ? new Event(type) : new ProgressEvent(type, { loaded, total: lengthComputable ? loaded : 0, lengthComputable }));
  };
  const fail = (xhr: any, type: 'error' | 'timeout' | 'abort') => {
    show(xhr, { readyState: 4, status: 0, statusText: '', response: xhr.responseType === '' || xhr.responseType === 'text' ? '' : null, responseText: '' });
    fire(xhr, 'readystatechange');
    fire(xhr, type);
    fire(xhr, 'loadend');
  };

  proto.open = function (this: any, method: string, url: string | URL, ...rest: unknown[]) {
    open.call(this, method, url, ...rest);
    requests.get(this)?.controller?.abort();
    for (const key of shown) delete this[key];
    const target = new URL(String(url), scope.location.href);
    const async = rest.length === 0 || Boolean(rest[0]);
    requests.set(this, {
      method,
      url: target.href,
      routed: async && rest[1] == null && rest[2] == null && ['http:', 'https:'].includes(target.protocol) && target.origin !== origin,
      headers: [],
      phase: 'opened',
    });
  };

  proto.setRequestHeader = function (this: any, name: string, value: string) {
    setRequestHeader.call(this, name, value);
    requests.get(this)?.headers.push([name, String(value)]);
  };

  proto.send = function (this: any, body?: any) {
    const state = requests.get(this);
    if (state && state.phase !== 'opened') {
      throw new DOMException("Failed to execute 'send' on 'XMLHttpRequest': The object's state must be OPENED.", 'InvalidStateError');
    }
    if (!state?.routed || !this.withCredentials || this.responseType === 'document' || (scope.Document && body instanceof scope.Document)) {
      return send.call(this, body);
    }
    const controller = new AbortController();
    let request: Request;
    try {
      request = new Request(state.url, {
        method: state.method,
        headers: state.headers,
        body: /^(GET|HEAD)$/i.test(state.method) ? undefined : body,
        credentials: 'include',
        signal: controller.signal,
      });
    } catch {
      return send.call(this, body);
    }
    state.phase = 'sent';
    state.controller = controller;
    const timer = this.timeout > 0 ? setTimeout(() => { state.timedOut = true; controller.abort(); }, this.timeout) : undefined;
    // Reopened or aborted: the request it was is over.
    const current = () => requests.get(this) === state && state.phase === 'sent';
    sendThroughLilo(scope, request).then(async (response) => {
      if (!current()) return;
      if (!response) {
        clearTimeout(timer);
        requests.delete(this);
        send.call(this, body);
        return;
      }
      // Fired once Lilo answers, not in send(): WebKit's send fires its own for a host Lilo leaves to it.
      fire(this, 'loadstart');
      if (!current()) return;
      const bytes = await response.arrayBuffer();
      if (!current()) return;
      const type = response.headers.get('content-type') ?? '';
      const charset = /;\s*charset=["']?([^;"']+)/i.exec(type)?.[1];
      let text: string;
      try {
        text = new TextDecoder(charset ?? 'utf-8').decode(bytes);
      } catch {
        text = new TextDecoder().decode(bytes);
      }
      let all = '';
      response.headers.forEach((value, name) => { all += `${name}: ${value}\r\n`; });
      const sized = response.headers.has('content-length');
      // A listener may abort or reopen the request at each event, which ends this one.
      show(this, {
        readyState: 2,
        status: response.status,
        statusText: '',
        responseURL: response.url,
        getResponseHeader: (name: string) => response.headers.get(name),
        getAllResponseHeaders: () => all,
      });
      fire(this, 'readystatechange');
      if (!current()) return;
      show(this, { readyState: 3 });
      fire(this, 'readystatechange');
      if (!current()) return;
      fire(this, 'progress', bytes.byteLength, sized);
      if (!current()) return;
      clearTimeout(timer);
      state.phase = 'done';
      const responseType = this.responseType;
      let value: unknown = text;
      if (responseType === 'json') {
        try { value = JSON.parse(text); } catch { value = null; }
      } else if (responseType === 'arraybuffer') {
        value = bytes;
      } else if (responseType === 'blob') {
        value = new Blob([bytes], { type });
      }
      const xml = responseType === '' && /^[^;]*[/+]xml\s*(;|$)/i.test(type) && typeof scope.DOMParser === 'function';
      show(this, {
        readyState: 4,
        response: value,
        responseText: responseType === '' || responseType === 'text' ? text : '',
        responseXML: xml ? new scope.DOMParser().parseFromString(text, 'application/xml') : null,
      });
      fire(this, 'readystatechange');
      fire(this, 'load', bytes.byteLength, sized);
      fire(this, 'loadend', bytes.byteLength, sized);
    }).catch(() => {
      if (!current()) return;
      fire(this, 'loadstart');
      if (!current()) return;
      clearTimeout(timer);
      state.phase = 'done';
      fail(this, state.timedOut ? 'timeout' : 'error');
    });
  };

  proto.abort = function (this: any) {
    const state = requests.get(this);
    if (state?.phase === 'sent') {
      state.phase = 'done';
      state.controller?.abort();
      fail(this, 'abort');
      // Unless an abort listener reopened it.
      if (requests.get(this) === state) show(this, { readyState: 0 });
    } else if (state?.phase === 'done') {
      show(this, { readyState: 0 });
    } else {
      abort.call(this);
    }
  };
}

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
    // The request, not `input`: building it took a body stream `init` or `input` held.
    return sendThroughLilo(scope, request).then((response) => response ?? fetch.call(scope, request));
  };
  if (typeof scope.XMLHttpRequest === 'function') routeCredentialedXHR(scope, origin);
}
