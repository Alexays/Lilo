import assert from 'node:assert';
import { test } from 'node:test';
import { mockGapAPI } from './ipc.testkit.ts';
import { collectGapListeners, GapChromeEvent, sendGapListeners } from './gap-event.ts';

test('GapChromeEvent sends the first event at once, then the rest of the task in one call', async () => {
  const calls: unknown[] = [];
  mockGapAPI((msg) => { calls.push(msg); });
  const visited = new GapChromeEvent('history', 'onVisited');
  const created = new GapChromeEvent('bookmarks', 'onCreated');
  const removed = new GapChromeEvent('bookmarks', 'onRemoved');
  visited.addListener(() => {});
  assert.deepEqual(calls, [{ namespace: 'events', method: 'listen', params: { events: ['history.onVisited'] } }]);
  visited.addListener(() => {});
  created.addListener(() => {});
  removed.addListener(() => {});
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(calls.slice(1), [{ namespace: 'events', method: 'listen', params: { events: ['bookmarks.onCreated', 'bookmarks.onRemoved'] } }]);
});

test('the worker reports the listeners its top-level code adds in one call, even none, once it has run', async () => {
  const calls: unknown[] = [];
  mockGapAPI((msg) => { calls.push(msg); });
  collectGapListeners();
  await new Promise((resolve) => setTimeout(resolve, 5));
  sendGapListeners();
  collectGapListeners();
  new GapChromeEvent('tabGroups', 'onCreated').addListener(() => {});
  await new Promise((resolve) => setTimeout(resolve, 5));
  new GapChromeEvent('tabGroups', 'onMoved').addListener(() => {});
  assert.deepEqual(calls, [{ namespace: 'events', method: 'listen', params: { events: [] } }], 'nothing is sent before the code has run');
  sendGapListeners();
  assert.deepEqual(calls.slice(1), [{ namespace: 'events', method: 'listen', params: { events: ['tabGroups.onCreated', 'tabGroups.onMoved'] } }]);
});
