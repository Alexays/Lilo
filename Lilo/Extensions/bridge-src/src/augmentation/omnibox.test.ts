import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const calls: unknown[] = [];
mockGapAPI((msg) => { if (msg.namespace === 'events') calls.push(msg); });

const { omniboxAugmentation } = await import('./omnibox.ts');

test('onInputChanged reports its last listener going', async () => {
  const first = () => {};
  const second = () => {};
  omniboxAugmentation.onInputChanged.addListener(first);
  omniboxAugmentation.onInputChanged.addListener(second);
  omniboxAugmentation.onInputChanged.removeListener(first);
  await new Promise((resolve) => setTimeout(resolve, 5));
  omniboxAugmentation.onInputChanged.removeListener(second);
  assert.deepEqual(calls, [
    { namespace: 'events', method: 'listen', params: { events: ['omnibox.onInputChanged'] } },
    { namespace: 'events', method: 'unlisten', params: { events: ['omnibox.onInputChanged'] } },
  ]);
});
