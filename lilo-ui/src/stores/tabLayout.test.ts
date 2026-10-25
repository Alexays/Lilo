import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

function stubRoot(): Record<string, string> {
	const dataset: Record<string, string> = {};
	(globalThis as { document: { documentElement?: unknown } }).document.documentElement = { dataset };
	return dataset;
}

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as { window: { __lilo: { receive(msg: unknown): void } } }).window.__lilo.receive(msg);
}

test("the address follows the position until chosen, and the root carries both", async () => {
	stubBridgeWindow({ document: true });
	const dataset = stubRoot();
	const store = await (await freshStores())("/src/stores/tabLayout.svelte.ts");

	store.applyTabLayoutInitialState({ tabPosition: "right" });

	assert.equal(store.getTabPosition(), "right");
	assert.equal(store.getAddressPlacement(), "page");
	assert.equal(store.hasPageToolbar(), true);
	assert.equal(dataset.tabPosition, "right");
	assert.equal(dataset.address, "page");
});

test("a layout change from the host moves the chrome", async () => {
	stubBridgeWindow({ document: true });
	const dataset = stubRoot();
	const store = await (await freshStores())("/src/stores/tabLayout.svelte.ts");
	store.initTabLayoutStore();

	receive({ event: "tabLayoutChanged", position: "top", address: "tabs" });

	assert.equal(dataset.tabPosition, "top");
	assert.equal(store.isVerticalLayout(), false);
	assert.equal(store.hasPageToolbar(), false, "on top the address row joins the strip instead");
});

test("choosing a position or an address stores the setting", async () => {
	const posted = stubBridgeWindow({ document: true });
	stubRoot();
	const store = await (await freshStores())("/src/stores/tabLayout.svelte.ts");

	store.setTabPosition("bottom");
	store.setAddressPlacement("tabs");

	const sets = posted.filter((m) => m.action === "setSetting").map((m) => m.payload);
	assert.deepEqual(sets, [
		{ key: "tabPosition", value: "bottom" },
		{ key: "addressPlacement", value: "tabs" },
	]);
});
