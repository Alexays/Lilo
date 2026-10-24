import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

test("the placeholder follows the tab another window took, and clears when native says so", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/banners.svelte.ts");
	store.initBannersStore();

	assert.equal(store.getContentPlaceholderTabId(), null);
	receive({ event: "contentPlaceholder", tabId: "tab-1" });
	assert.equal(store.getContentPlaceholderTabId(), "tab-1");
	receive({ event: "contentPlaceholder", tabId: "" });
	assert.equal(store.getContentPlaceholderTabId(), null);
});

test("taking the tab back asks native to show it in this window", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const actions = await loadStore("/src/lib/bridge/actions.ts");

	actions.tabActions.claim("tab-1");

	assert.deepEqual(posted.at(-1), { action: "claimTab", payload: { id: "tab-1" } });
});
