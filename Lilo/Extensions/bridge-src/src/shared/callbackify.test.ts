import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { callbackify } from './callbackify.ts';
import { installChromeCompat } from './chrome-compat.ts';

// WebKit's runtime.lastError is an own property nothing can redefine.
function install(): any {
  const runtime = { getManifest: () => ({ permissions: [] }) };
  Object.defineProperty(runtime, 'lastError', { get: () => undefined, enumerable: true });
  (globalThis as any).chrome = { runtime };
  installChromeCompat({});
  return (globalThis as any).chrome;
}

async function errors(run: () => Promise<void>): Promise<unknown[]> {
  const logged: unknown[] = [];
  const error = console.error;
  console.error = (message: unknown) => { logged.push(message); };
  try {
    await run();
  } finally {
    console.error = error;
  }
  return logged;
}

describe('callbackify', () => {
  it('serves the error as chrome.runtime.lastError while the callback runs only', async () => {
    const chrome = install();
    let seen: unknown;
    const logged = await errors(() => new Promise<void>((resolve) => {
      callbackify(() => Promise.reject(new Error('boom')), () => { seen = chrome.runtime.lastError; resolve(); });
    }));
    assert.deepEqual(seen, { message: 'boom' });
    assert.equal(chrome.runtime.lastError, undefined);
    assert.deepEqual(logged, []);
  });

  it('logs the error as Chrome does when the callback does not read it', async () => {
    install();
    const logged = await errors(() => new Promise<void>((resolve) => {
      callbackify(() => Promise.reject(new Error('boom')), () => resolve());
    }));
    assert.deepEqual(logged, ['Unchecked runtime.lastError: boom']);
  });

  it('logs an exception thrown from the callback as Chrome does', async () => {
    install();
    const logged = await errors(async () => {
      callbackify(async () => 1, () => { throw new TypeError('on success'); });
      callbackify(() => Promise.reject(new Error('boom')), () => { void (globalThis as any).chrome.runtime.lastError; throw new Error('on error'); });
      await new Promise((resolve) => setTimeout(resolve));
    });
    assert.deepEqual(logged, ['Error handling response: TypeError: on success', 'Error handling response: Error: on error']);
  });

  it('leaves lastError unset on success and rejects the promise without a callback', async () => {
    const chrome = install();
    const seen = await new Promise((resolve) => callbackify(async () => 1, () => resolve(chrome.runtime.lastError)));
    assert.equal(seen, undefined);
    await assert.rejects(callbackify(() => Promise.reject(new Error('boom')))!, { message: 'boom' });
  });
});
