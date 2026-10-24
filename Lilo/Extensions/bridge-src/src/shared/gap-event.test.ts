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

test('removing the last listener of an event reports it, and a listener added again is reported anew', async () => {
  const calls: unknown[] = [];
  mockGapAPI((msg) => { calls.push(msg); });
  const changed = new GapChromeEvent('sessions', 'onChanged');
  const first = () => {};
  const second = () => {};
  changed.addListener(first);
  changed.addListener(second);
  changed.removeListener(first);
  changed.removeListener(second);
  await new Promise((resolve) => setTimeout(resolve, 5));
  changed.addListener(first);
  assert.deepEqual(calls, [
    { namespace: 'events', method: 'listen', params: { events: ['sessions.onChanged'] } },
    { namespace: 'events', method: 'unlisten', params: { events: ['sessions.onChanged'] } },
    { namespace: 'events', method: 'listen', params: { events: ['sessions.onChanged'] } },
  ]);
});

test('a listener added and removed before its batch is sent is never reported', async () => {
  const calls: unknown[] = [];
  mockGapAPI((msg) => { calls.push(msg); });
  const visitRemoved = new GapChromeEvent('history', 'onVisitRemoved');
  const moved = new GapChromeEvent('bookmarks', 'onMoved');
  const listener = () => {};
  visitRemoved.addListener(listener);
  moved.addListener(listener);
  moved.removeListener(listener);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(calls, [{ namespace: 'events', method: 'listen', params: { events: ['history.onVisitRemoved'] } }]);
});
