import assert from 'node:assert';
import { test } from 'node:test';
import { closeGapChannel, mockGapAPI } from './ipc.testkit.ts';
import { collectGapListeners, GapChromeEvent, GapWrappedEvent, sendGapListeners } from './gap-event.ts';

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

test("a page's onConnect listener goes at once, even after another listener", async () => {
  const calls: unknown[] = [];
  mockGapAPI((msg) => { calls.push(msg); });
  new GapChromeEvent('history', 'onTitleChanged').addListener(() => {});
  new GapChromeEvent('runtime', 'onConnect').addListener(() => {});
  assert.deepEqual(calls.slice(-1), [{ namespace: 'events', method: 'listen', params: { events: ['runtime.onConnect'] } }]);
  await new Promise((resolve) => setTimeout(resolve, 5));
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

test('a GapWrappedEvent reports its last listener going', async () => {
  const calls: unknown[] = [];
  mockGapAPI((msg) => { calls.push(msg); });
  const webKit = Object.create({ addListener() {}, removeListener() {} });
  const external = new GapWrappedEvent('runtime.onMessageExternal', () => webKit, (listener) => listener, () => {});
  const first = () => {};
  const second = () => {};
  external.addListener(first);
  external.addListener(second);
  external.removeListener(first);
  await new Promise((resolve) => setTimeout(resolve, 5));
  external.removeListener(second);
  assert.deepEqual(calls, [
    { namespace: 'events', method: 'listen', params: { events: ['runtime.onMessageExternal'] } },
    { namespace: 'events', method: 'unlisten', params: { events: ['runtime.onMessageExternal'] } },
  ]);
});

test('a page reports its listeners again on the channel after a closed one, and one Lilo failed to record on its next listener', async () => {
  const calls: any[] = [];
  let refuse = true;
  mockGapAPI((msg) => {
    calls.push(msg);
    if (refuse && msg.params.events.includes('alarms.onAlarm')) {
      refuse = false;
      throw new Error('refused');
    }
  });
  new GapChromeEvent('idle', 'onStateChanged').addListener(() => {});
  const alarm = new GapChromeEvent('alarms', 'onAlarm');
  alarm.addListener(() => {});
  await new Promise((resolve) => setTimeout(resolve, 5));
  closeGapChannel();
  alarm.addListener(() => {});
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(calls.slice(0, 2).map((call) => call.params.events), [['idle.onStateChanged'], ['alarms.onAlarm']]);
  assert.equal(calls.length, 4);
  assert.ok(calls[2].params.events.includes('idle.onStateChanged'), 'the reported listeners go again on the new channel');
  assert.ok(!calls[2].params.events.includes('alarms.onAlarm'));
  assert.deepEqual(calls[3].params.events, ['alarms.onAlarm'], 'the failed report goes again with the next listener');
});
