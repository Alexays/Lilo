import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ChromeEvent } from './chrome-event.ts';

describe('ChromeEvent', () => {
  it('calls a listener re-registering itself once per event, not again in the same dispatch', () => {
    const event = new ChromeEvent<[number]>();
    const calls: number[] = [];
    const rearm = (n: number) => {
      calls.push(n);
      event.removeListener(rearm);
      event.addListener(rearm);
    };
    event.addListener(rearm);

    event.dispatch(1);
    event.dispatch(2);

    assert.deepEqual(calls, [1, 2]);
  });

  it('leaves a listener added during dispatch for the next event', () => {
    const event = new ChromeEvent<[]>();
    let late = 0;
    event.addListener(() => event.addListener(() => { late += 1; }));

    event.dispatch();

    assert.equal(late, 0);
  });
});
