import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

test("a stale history page reply still keeps its favicons, which the native side sends only once", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/history.svelte.ts");
	store.openHistory();
	store.showHistoryPeriod("today");
	const requestIds = posted.filter((message) => message.action === "loadHistoryPage").map((message) => message.payload.requestId);
	assert.deepEqual(requestIds, [1, 2]);

	(globalThis as unknown as LiloWindow).window.__lilo?.receive({
		event: "historyPage",
		requestId: requestIds[0],
		rows: [{ id: 1, url: "https://stale.example/", title: "Stale", host: "stale.example", visitedAt: 1 }],
		favicons: { "stale.example": "data:image/png;base64,AA==" },
	});

	assert.deepEqual(store.getHistoryRows(), []);
	assert.equal(store.getHistoryFavicon("stale.example"), "data:image/png;base64,AA==");
});
