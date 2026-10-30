import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

const HOUR = 3_600_000;

test("asks native for the list once, then keeps only the last day's tabs one click away", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/archivedTabs.svelte.ts");
	store.initArchivedTabsStore();
	assert.ok(posted.some((message) => message.action === "loadArchivedTabs"));

	const now = 10 * 24 * HOUR;
	(globalThis as unknown as LiloWindow).window.__lilo?.receive({
		event: "archivedTabs",
		tabs: [
			{ id: "today", url: "https://news.example/", title: "News", archivedAt: now - 9 * HOUR },
			{ id: "older", url: "https://docs.example/", title: "Docs", archivedAt: now - 3 * 24 * HOUR },
		],
		favicons: { "news.example": "data:image/png;base64,AA==" },
	});

	assert.deepEqual(store.getRecentArchivedTabs(now).map((tab: { id: string }) => tab.id), ["today"]);
	assert.deepEqual(store.getArchivedFavicons(), { "news.example": "data:image/png;base64,AA==" });
});
