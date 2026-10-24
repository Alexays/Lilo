import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from './ipc.testkit.ts';
import { installCredentialedFetch } from './credentialed-fetch.ts';

const calls: any[] = [];
let answer: unknown = null;
mockGapAPI((call) => {
  calls.push(call.params);
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
});
