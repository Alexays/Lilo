import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

(globalThis as any).chrome = { runtime: {} };
const { declarativeContentAugmentation: content } = await import('./declarativeContent.ts');

describe('declarativeContent', () => {
  it("builds conditions and actions with Chrome's instanceType", () => {
    assert.deepEqual({ ...new content.PageStateMatcher({ pageUrl: { hostEquals: 'a.com' } }) }, {
      pageUrl: { hostEquals: 'a.com' }, instanceType: 'declarativeContent.PageStateMatcher',
    });
    assert.equal(new content.RequestContentScript({ js: ['a.js'] }).instanceType, 'declarativeContent.RequestContentScript');
  });

  it("keeps onPageChanged's rules with Chrome's ids and defaults", async () => {
    const rule = { conditions: [new content.PageStateMatcher({})], actions: [new content.ShowAction()] };
    const [added] = await content.onPageChanged.addRules([rule])!;
    assert.match(added.id!, /^_\d+_$/);
    assert.equal(added.priority, 100);
    assert.deepEqual(added.tags, []);
    await new Promise<void>((resolve) => content.onPageChanged.addRules([{ ...rule, id: 'mine' }], () => resolve()));
    assert.deepEqual((await content.onPageChanged.getRules(['mine', 'other'])!).map((r) => r.id), ['mine']);

    await new Promise<void>((resolve) => content.onPageChanged.removeRules(undefined, resolve));
    assert.deepEqual(await content.onPageChanged.getRules()!, []);
  });

  it('takes no listeners, as a declarative event', () => {
    assert.throws(() => content.onPageChanged.addListener(), { message: 'This event does not support listeners.' });
    assert.equal(content.onPageChanged.hasListeners(), false);
  });
});
