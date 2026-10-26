import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

const gapCalls: Array<{ namespace: string; method: string; params: any }> = [];
let nextResult: unknown;

mockGapAPI((msg: any) => {
  gapCalls.push({ namespace: msg.namespace, method: msg.method, params: msg.params });
  return nextResult;
});

(globalThis as any).chrome = {
  windows: {
    getAll: async () => [{ id: 7 }, { id: 9 }],
    getCurrent: async () => ({ id: 9 }),
  },
};

const { tabGroupsAugmentation } = await import('./tabGroups.ts');

const group = (id: number, windowPosition: number) => ({ id, title: '', color: 'grey', collapsed: false, windowPosition });

beforeEach(() => {
  gapCalls.length = 0;
});

describe('tabGroups.query', () => {
  beforeEach(() => {
    nextResult = { groups: [group(1, 0), group(2, 1), group(3, -1)] };
  });

  it("names each group's own window, across every window", async () => {
    const groups = (await tabGroupsAugmentation.query({}))!;

    assert.deepEqual(groups.map((g: any) => [g.id, g.windowId]), [[1, 7], [2, 9], [3, -1]]);
    assert.equal('windowPosition' in groups[0], false);
    assert.deepEqual(gapCalls.map((c) => `${c.namespace}.${c.method}`), ['tabGroups.query']);
  });

  it('keeps the groups of the window asked for, the current one for WINDOW_ID_CURRENT', async () => {
    assert.deepEqual((await tabGroupsAugmentation.query({ windowId: -2 }))!.map((g: any) => g.id), [2]);
    assert.deepEqual((await tabGroupsAugmentation.query({ windowId: 7 }))!.map((g: any) => g.id), [1]);
    assert.deepEqual(await tabGroupsAugmentation.query({ windowId: 42 }), []);
  });
});

describe('tabGroups.get', () => {
  it("names the group's window rather than the current one", async () => {
    nextResult = { group: group(4, 0) };

    assert.deepEqual(await tabGroupsAugmentation.get(4), { id: 4, title: '', color: 'grey', collapsed: false, windowId: 7 });
  });
});

describe('tabGroups events', () => {
  it("resolve a pushed group's window", async () => {
    const heard = new Promise<any>((resolve) => tabGroupsAugmentation.onCreated.addListener(resolve));

    tabGroupsAugmentation.onCreated.dispatch(group(5, 1));

    assert.equal((await heard).windowId, 9);
  });

  it('onMoved, which Lilo never fires, tells Lilo nothing', async () => {
    tabGroupsAugmentation.onMoved.addListener(() => {});
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(gapCalls, []);
  });
});
