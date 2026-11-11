import { describe, it, beforeEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI, pushGapEvent } from './ipc.testkit.ts';
import { installCredentialedFetch } from './credentialed-fetch.ts';

const calls: any[] = [];
let answer: unknown = null;
const pushBody = (requestId: string, part: { chunk: string } | { failed: boolean }) => pushGapEvent({ namespace: 'fetch', event: 'onBody', args: [{ requestId, ...part }] });
// A cancel or a read is answered at once: left pending, its 30 s ipc timeout would keep the test process alive.
// An answer's `body` follows its head whole, then its end.
mockGapAPI((call) => {
  calls.push(call.params);
  if (call.method !== 'credentialed') return null;
  Promise.resolve(answer).then((head: any) => {
    if (typeof head?.body !== 'string') return;
    pushBody(call.params.requestId, { chunk: head.body });
    pushBody(call.params.requestId, { failed: false });
  }, () => {});
  return answer;
});

describe('credentialed fetch', () => {
  const sent: string[] = [];
  const scope: any = {
    location: { protocol: 'chrome-extension:', host: 'abc' },
    navigator: { userAgent: 'Chrome' },
    fetch: async (input: RequestInfo | URL) => {
      sent.push(input instanceof Request ? `webkit ${input.url}` : `webkit ${String(input)}`);
      return new Response('webkit');
    },
  };
  installCredentialedFetch(scope);

  beforeEach(() => {
    calls.length = 0;
    sent.length = 0;
    answer = null;
  });

  it('leaves to WebKit what it sends as Chrome does', async () => {
    await scope.fetch('https://example.com/a');
    await scope.fetch('https://example.com/b', { credentials: 'omit' });
    await scope.fetch('chrome-extension://abc/c', { credentials: 'include' });
    await scope.fetch('https://example.com/d', { credentials: 'include', redirect: 'manual' });
    assert.deepEqual(sent, ['webkit https://example.com/a', 'webkit https://example.com/b', 'webkit chrome-extension://abc/c', 'webkit https://example.com/d']);
    assert.equal(calls.length, 0);
  });

  it("sends a credentialed request to another site through Lilo, and answers Lilo's response", async () => {
    answer = { status: 201, headers: [['content-type', 'application/json']], body: btoa('{"user":1}'), url: 'https://example.com/final', redirected: true };
    const response = await scope.fetch('https://example.com/session', { credentials: 'include', method: 'POST', body: 'x=1', headers: { 'X-Test': '1' } });
    assert.deepEqual(await response.json(), { user: 1 });
    assert.deepEqual([response.status, response.url, response.redirected, response.headers.get('content-type')], [201, 'https://example.com/final', true, 'application/json']);
    assert.equal(calls[0].url, 'https://example.com/session');
    assert.equal(calls[0].method, 'POST');
    assert.equal(atob(calls[0].body), 'x=1');
    assert.deepEqual(calls[0].headers.find(([name]: string[]) => name === 'x-test'), ['x-test', '1']);
    assert.equal(sent.length, 0);
  });

  it('falls back to WebKit for a host the extension may not access', async () => {
    const response = await scope.fetch(new Request('https://other.example/', { credentials: 'include' }));
    assert.equal(await response.text(), 'webkit');
    assert.deepEqual(sent, ['webkit https://other.example/']);
  });

  it('rejects as fetch does once aborted', async () => {
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(scope.fetch('https://example.com/', { credentials: 'include', signal: controller.signal }), { name: 'AbortError' });
  });

  it('cancels the request in Lilo when aborted in flight, as Chrome stops it', async () => {
    answer = new Promise(() => {});
    const controller = new AbortController();
    const response = scope.fetch('https://example.com/poll', { credentials: 'include', signal: controller.signal });
    await new Promise((resolve) => setImmediate(resolve));
    controller.abort();
    await assert.rejects(response, { name: 'AbortError' });
    const [sentRequest, cancel] = calls;
    assert.equal(typeof sentRequest.requestId, 'string');
    assert.deepEqual(cancel, { requestId: sentRequest.requestId });
  });

  it('yields each chunk as it arrives, before the response ends', async () => {
    answer = { status: 200, headers: [['content-type', 'text/event-stream']], url: 'https://example.com/stream', redirected: false };
    const response = await scope.fetch('https://example.com/stream', { credentials: 'include' });
    const reader = response.body.getReader();
    const { requestId } = calls[0];
    pushBody(requestId, { chunk: btoa('data: one\n\n') });
    assert.equal(new TextDecoder().decode((await reader.read()).value), 'data: one\n\n');
    pushBody(requestId, { chunk: btoa('data: two\n\n') });
    pushBody(requestId, { failed: false });
    assert.equal(new TextDecoder().decode((await reader.read()).value), 'data: two\n\n');
    assert.equal((await reader.read()).done, true);
  });

  it('cancels the request in Lilo when aborted while its body is read', async () => {
    answer = { status: 200, headers: [], url: 'https://example.com/stream', redirected: false };
    const controller = new AbortController();
    const response = await scope.fetch('https://example.com/stream', { credentials: 'include', signal: controller.signal });
    const reader = response.body.getReader();
    pushBody(calls[0].requestId, { chunk: btoa('one') });
    await reader.read();
    controller.abort();
    await assert.rejects(reader.read(), { name: 'AbortError' });
    assert.deepEqual(calls[1], { requestId: calls[0].requestId });
  });

  it('fails the body when the response breaks off', async () => {
    answer = { status: 200, headers: [], url: 'https://example.com/stream', redirected: false };
    const response = await scope.fetch('https://example.com/stream', { credentials: 'include' });
    pushBody(calls[0].requestId, { failed: true });
    await assert.rejects(response.text(), TypeError);
  });

  it('tells Lilo what it read only once it has taken half of what Lilo lets go unread', async () => {
    answer = { status: 200, headers: [], url: 'https://example.com/file', redirected: false };
    const response = await scope.fetch('https://example.com/file', { credentials: 'include' });
    const reader = response.body.getReader();
    const { requestId } = calls[0];
    pushBody(requestId, { chunk: btoa('x'.repeat(1024)) });
    await reader.read();
    assert.equal(calls.length, 1);
    pushBody(requestId, { chunk: btoa('x'.repeat(512 * 1024)) });
    await reader.read();
    assert.deepEqual(calls[1], { requestId, bytes: 513 * 1024 });
  });

  it('waits past the ipc timeout for a long poll', async () => {
    let release!: (value: unknown) => void;
    answer = new Promise((resolve) => { release = resolve; });
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const response = scope.fetch('https://example.com/poll', { credentials: 'include' });
      mock.timers.tick(60_000);
      release({ status: 200, headers: [], body: btoa('late'), url: 'https://example.com/poll', redirected: false });
      assert.equal(await (await response).text(), 'late');
    } finally {
      mock.timers.reset();
    }
  });

  it('ignores an abort once settled', async () => {
    const controller = new AbortController();
    const rejections: unknown[] = [];
    const track = (reason: unknown) => rejections.push(reason);
    process.on('unhandledRejection', track);
    try {
      answer = { status: 200, headers: [], body: btoa('done'), url: 'https://example.com/', redirected: false };
      await scope.fetch('https://example.com/', { credentials: 'include', signal: controller.signal });
      controller.abort();
      await new Promise((resolve) => setImmediate(resolve));
    } finally {
      process.off('unhandledRejection', track);
    }
    assert.deepEqual(rejections, []);
  });
});

describe('credentialed XMLHttpRequest', () => {
  (globalThis as any).ProgressEvent ??= class extends Event {
    loaded: number;
    total: number;
    lengthComputable: boolean;
    constructor(type: string, init: ProgressEventInit = {}) {
      super(type);
      this.loaded = init.loaded ?? 0;
      this.total = init.total ?? 0;
      this.lengthComputable = init.lengthComputable ?? false;
    }
  };
  const sent: string[] = [];
  // WebKit's request, its state behind prototype getters and its handler attributes fired by dispatchEvent.
  class WebKitXHR extends EventTarget {
    withCredentials = false;
    responseType = '';
    timeout = 0;
    webkitState = 0;
    url = '';
    get readyState() { return this.webkitState; }
    get status() { return 0; }
    get responseText() { return ''; }
    open(_method: string, url: string) { this.webkitState = 1; this.url = url; }
    setRequestHeader() {}
    send() { sent.push(`webkit ${this.url}`); }
    abort() {}
    override dispatchEvent(event: Event): boolean {
      const result = super.dispatchEvent(event);
      (this as any)[`on${event.type}`]?.call(this, event);
      return result;
    }
  }
  const scope: any = {
    location: { protocol: 'chrome-extension:', host: 'abc', href: 'chrome-extension://abc/page.html' },
    navigator: { userAgent: 'Chrome' },
    fetch: async () => new Response('webkit'),
    XMLHttpRequest: WebKitXHR,
  };
  installCredentialedFetch(scope);

  /** The request's events as `type readyState`, once it ends. */
  function events(xhr: any): Promise<string[]> {
    const seen: string[] = [];
    return new Promise((resolve) => {
      for (const type of ['loadstart', 'readystatechange', 'progress', 'load', 'error', 'abort', 'timeout']) {
        xhr.addEventListener(type, () => seen.push(`${type} ${xhr.readyState}`));
      }
      xhr.addEventListener('loadend', () => resolve([...seen, `loadend ${xhr.readyState}`]));
    });
  }

  beforeEach(() => {
    calls.length = 0;
    sent.length = 0;
    answer = null;
  });

  it('leaves to WebKit a request without credentials, to its own origin or synchronous', () => {
    const plain = new scope.XMLHttpRequest();
    plain.open('GET', 'https://example.com/a');
    plain.send();
    const own = new scope.XMLHttpRequest();
    own.open('GET', '/b');
    own.withCredentials = true;
    own.send();
    const sync = new scope.XMLHttpRequest();
    sync.open('GET', 'https://example.com/c', false);
    sync.withCredentials = true;
    sync.send();
    assert.deepEqual(sent, ['webkit https://example.com/a', 'webkit /b', 'webkit https://example.com/c']);
    assert.equal(calls.length, 0);
  });

  it("answers Lilo's response with XMLHttpRequest's states and events", async () => {
    answer = { status: 200, headers: [['content-type', 'application/json'], ['x-test', '1']], body: btoa('{"user":1}'), url: 'https://example.com/final', redirected: true };
    const xhr = new scope.XMLHttpRequest();
    xhr.open('POST', 'https://example.com/session');
    xhr.setRequestHeader('X-Test', '1');
    xhr.withCredentials = true;
    xhr.responseType = 'json';
    let loaded = false;
    xhr.onload = () => { loaded = true; };
    const ended = events(xhr);
    xhr.send('x=1');
    assert.equal(xhr.readyState, 1);
    assert.deepEqual(await ended, ['loadstart 1', 'readystatechange 2', 'readystatechange 3', 'progress 3', 'readystatechange 4', 'load 4', 'loadend 4']);
    assert.ok(loaded);
    assert.deepEqual(xhr.response, { user: 1 });
    assert.deepEqual([xhr.status, xhr.responseURL, xhr.getResponseHeader('X-Test')], [200, 'https://example.com/final', '1']);
    assert.equal(xhr.getAllResponseHeaders(), 'content-type: application/json\r\nx-test: 1\r\n');
    assert.equal(calls[0].method, 'POST');
    assert.equal(atob(calls[0].body), 'x=1');
    assert.deepEqual(calls[0].headers.find(([name]: string[]) => name === 'x-test'), ['x-test', '1']);
    assert.equal(sent.length, 0);
  });

  it('answers text, an array buffer or a blob as its response type asks', async () => {
    for (const [responseType, check] of [
      ['', (xhr: any) => assert.deepEqual([xhr.response, xhr.responseText], ['café', 'café'])],
      ['arraybuffer', (xhr: any) => assert.equal(xhr.response.byteLength, 5)],
      ['blob', async (xhr: any) => assert.equal(await xhr.response.text(), 'café')],
    ] as const) {
      answer = { status: 200, headers: [['content-type', 'text/plain; charset=utf-8']], body: btoa('cafÃ©'), url: 'https://example.com/', redirected: false };
      const xhr = new scope.XMLHttpRequest();
      xhr.open('GET', 'https://example.com/');
      xhr.withCredentials = true;
      xhr.responseType = responseType;
      const ended = events(xhr);
      xhr.send();
      await ended;
      await check(xhr);
    }
  });

  it('falls back to WebKit for a host the extension may not access', async () => {
    const xhr = new scope.XMLHttpRequest();
    xhr.open('GET', 'https://other.example/');
    xhr.withCredentials = true;
    xhr.send();
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(sent, ['webkit https://other.example/']);
  });

  it('ends with error and status 0 when Lilo cannot reach the site', async () => {
    answer = Promise.reject(new Error('Failed to fetch'));
    (answer as Promise<unknown>).catch(() => {});
    const xhr = new scope.XMLHttpRequest();
    xhr.open('GET', 'https://example.com/');
    xhr.withCredentials = true;
    const ended = events(xhr);
    xhr.send();
    assert.deepEqual(await ended, ['loadstart 1', 'readystatechange 4', 'error 4', 'loadend 4']);
    assert.equal(xhr.status, 0);
  });

  it('ends with abort, then unsent, once aborted', async () => {
    answer = new Promise(() => {});
    const xhr = new scope.XMLHttpRequest();
    xhr.open('GET', 'https://example.com/');
    xhr.withCredentials = true;
    const ended = events(xhr);
    xhr.send();
    xhr.abort();
    assert.deepEqual(await ended, ['loadstart 1', 'readystatechange 4', 'abort 4', 'loadend 4']);
    assert.equal(xhr.readyState, 0);
    assert.throws(() => xhr.send(), { name: 'InvalidStateError' });
  });
});
