import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { closeGapChannel, mockGapAPI } from './ipc.testkit.ts';

// An extension page's window, which ipc.ts watches for its going away.
const page = new EventTarget();
(globalThis as any).addEventListener = page.addEventListener.bind(page);
mockGapAPI(() => new Promise(() => {}));
const { gapCall } = await import('./ipc.ts');

describe("a page's channel", () => {
  it('fails the calls it cuts while the page stays', async () => {
    const call = gapCall('bookmarks', 'get', {});
    closeGapChannel();
    await assert.rejects(call, { message: 'Lilo is unreachable' });
  });

  it('settles nothing more once the page goes, as Chrome', async () => {
    const call = gapCall('bookmarks', 'get', {});
    page.dispatchEvent(new Event('pagehide'));
    closeGapChannel();
    const settled = await Promise.race([call.then(() => 'resolved', () => 'rejected'), new Promise((resolve) => setTimeout(() => resolve('pending'), 20))]);
    assert.equal(settled, 'pending');
  });
});
