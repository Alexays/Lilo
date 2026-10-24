// Covers the bookmarks param contract between JS and Swift: array get uses "ids", update flattens
// changes, object search passes url/title/query at the top level.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: unknown }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return new Promise((resolve) => setImmediate(() => resolve(nextResult)));
});

const { bookmarksAugmentation } = await import('./bookmarks.ts');

describe('bookmarksAugmentation', () => {
  it('get sends a single id under "id"', async () => {
    gapCalls.length = 0;
    nextResult = [];

    await bookmarksAugmentation.get('42');

    assert.deepEqual(gapCalls[0], {
      namespace: 'bookmarks',
      method: 'get',
      params: { id: '42' },
    });
  });

  it('get sends an id list under "ids"', async () => {
    gapCalls.length = 0;
    nextResult = [];

    await bookmarksAugmentation.get(['1', '2']);

    assert.deepEqual(gapCalls[0], {
      namespace: 'bookmarks',
      method: 'get',
      params: { ids: ['1', '2'] },
    });
  });

  it('update flattens changes to the top level', async () => {
    gapCalls.length = 0;
    nextResult = {};

    await bookmarksAugmentation.update('7', { title: 'New', url: 'https://example.com/' });

    assert.deepEqual(gapCalls[0], {
      namespace: 'bookmarks',
      method: 'update',
      params: { id: '7', title: 'New', url: 'https://example.com/' },
    });
  });

  it('search wraps a string query under "query"', async () => {
    gapCalls.length = 0;
    nextResult = [];

    await bookmarksAugmentation.search('lilo');

    assert.deepEqual(gapCalls[0], {
      namespace: 'bookmarks',
      method: 'search',
      params: { query: 'lilo' },
    });
  });

  it('search sends an object query at the top level', async () => {
    gapCalls.length = 0;
    nextResult = [];

    await bookmarksAugmentation.search({ url: 'https://example.com/', title: 'Example' });

    assert.deepEqual(gapCalls[0], {
      namespace: 'bookmarks',
      method: 'search',
      params: { url: 'https://example.com/', title: 'Example' },
    });
  });
});
