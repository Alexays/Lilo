import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

test("the shown list keeps its filter while a search is typed, until the search's rows arrive", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/history.svelte.ts");
	const receive = (msg: Record<string, unknown>) => (globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
	const lastRequestId = () => posted.filter((message) => message.action === "loadHistoryPage").at(-1)?.payload.requestId;

	mock.timers.enable({ apis: ["setTimeout"] });
	try {
		store.openHistory();
		receive({ event: "historyPage", requestId: lastRequestId(), rows: [], favicons: {} });

		store.setHistoryQuery("example");
		assert.equal(store.getHistoryFilter().query, "example");
		assert.equal(store.getShownHistoryFilter().query, "");

		mock.timers.tick(150);
		assert.equal(posted.at(-1)?.payload.query, "example");
		assert.equal(store.getShownHistoryFilter().query, "");

		receive({ event: "historyPage", requestId: lastRequestId(), rows: [], favicons: {} });
		assert.equal(store.getShownHistoryFilter().query, "example");
	} finally {
		mock.timers.reset();
	}
});
