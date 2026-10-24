import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { tab } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("live refresh throttles hover sweeps to one memory load per interval", async () => {
	const posted = stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const { startTabMemoryLiveRefresh, stopTabMemoryLiveRefresh } =
		await loadStore("/src/stores/tabMemory.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: 0 });
	try {
		const loads = () =>
			posted.filter((m) => m.action === "getTabMemory").length;

		startTabMemoryLiveRefresh("tab-1");
		assert.equal(loads(), 1, "first hover loads immediately");
		stopTabMemoryLiveRefresh();

		// Re-hover shortly after: the first tick waits out the interval remainder.
		mock.timers.tick(500);
		startTabMemoryLiveRefresh("tab-1");
		assert.equal(loads(), 1);
		mock.timers.tick(1499);
		assert.equal(loads(), 1);
		mock.timers.tick(1);
		assert.equal(loads(), 2, "throttled first tick fires after the remainder");

		mock.timers.tick(2000);
		assert.equal(loads(), 3, "regular interval keeps refreshing");

		// A held hover backs off: the next snapshot waits 4 s, then 8 s.
		mock.timers.tick(2000);
		assert.equal(loads(), 3);
		mock.timers.tick(2000);
		assert.equal(loads(), 4, "third tick lands after 4 s");
		mock.timers.tick(8000);
		assert.equal(loads(), 5, "fourth tick lands after 8 s");
		stopTabMemoryLiveRefresh();

		// Stopping while the throttled first tick is pending cancels it.
		mock.timers.tick(500);
		startTabMemoryLiveRefresh("tab-1");
		stopTabMemoryLiveRefresh();
		mock.timers.tick(10_000);
		assert.equal(loads(), 5);
	} finally {
		mock.timers.reset();
	}
});

test("the usage label adds CPU once a reading has one", async () => {
	stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const { initTabMemoryStore, tabUsageLabel } = await loadStore("/src/stores/tabMemory.svelte.ts");
	initTabMemoryStore();
	const receive = (globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }).window.__lilo!.receive;

	assert.equal(tabUsageLabel("tab-1"), "");
	receive({ event: "tabMemoryUpdated", tabId: "tab-1", bytes: 120 * 1024 * 1024 });
	assert.match(tabUsageLabel("tab-1"), /^Memory ≈ 120/);
	assert.doesNotMatch(tabUsageLabel("tab-1"), /CPU/);

	receive({ event: "tabMemoryUpdated", tabId: "tab-1", bytes: 120 * 1024 * 1024, cpuPercent: 0.3 });
	assert.match(tabUsageLabel("tab-1"), /· CPU <1%$/);
	receive({ event: "tabMemoryUpdated", tabId: "tab-1", bytes: 120 * 1024 * 1024, cpuPercent: 142.6 });
	assert.match(tabUsageLabel("tab-1"), /· CPU 143%$/);
});

test("a closed tab's usage is dropped", async () => {
	stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const memory = await loadStore("/src/stores/tabMemory.svelte.ts");
	(await loadStore("/src/stores/sidebar.svelte.ts")).initSidebarStore();
	memory.initTabMemoryStore();
	const receive = (globalThis as unknown as { window: { __lilo: { receive(msg: Record<string, unknown>): void } } })
		.window.__lilo.receive;
	receive({
		event: "browserStateChanged",
		changedSpaceId: "s1",
		states: [{ spaceId: "s1", activeTabId: "t2", tabs: [tab("t1", "s1"), tab("t2", "s1")], folders: [], treeItems: [] }],
	});
	receive({ event: "tabMemoryUpdated", tabId: "t1", bytes: 50 * 1024 ** 2, cpuPercent: 3 });
	assert.equal(memory.tabUsage("t1")?.memory, "50 MB");

	receive({
		event: "browserStatePatch",
		operations: [{ kind: "sidebarChanged", spaceId: "s1", activeTabId: "t2", removedTabIds: ["t1"] }],
	});

	assert.equal(memory.tabUsage("t1"), null);
});
