import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

function stubRoot(): Record<string, string> {
	const dataset: Record<string, string> = {};
	(globalThis as { document: { documentElement?: unknown } }).document.documentElement = { dataset, classList: { contains: () => false } };
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

test("a hidden address stays hidden on every edge, including the right", async () => {
	stubBridgeWindow({ document: true });
	const dataset = stubRoot();
	const store = await (await freshStores())("/src/stores/tabLayout.svelte.ts");

	for (const position of ["left", "right", "top", "bottom"]) {
		store.applyTabLayoutInitialState({ tabPosition: position, addressPlacement: "hidden" });
		assert.equal(store.getAddressPlacement(), "hidden", position);
		assert.equal(store.isAddressVisible(), false, position);
		assert.equal(dataset.address, "hidden", position);
		assert.equal(store.hasPageToolbar(), position === "right" || position === "bottom", "only navigation keeps its row");
	}
});

test("on the left and the top the address toolbar hides apart from the tabs, taking the address along", async () => {
	stubBridgeWindow({ document: true });
	const dataset = stubRoot();
	const store = await (await freshStores())("/src/stores/tabLayout.svelte.ts");
	store.initTabLayoutStore();

	for (const position of ["left", "top"]) {
		store.applyTabLayoutInitialState({ tabPosition: position, addressPlacement: "page", toolbarVisible: true });
		assert.equal(store.canHideToolbar(), true, position);
		assert.equal(store.isPageToolbarShown(), true, position);

		receive({ event: "toolbarVisibilityChanged", visible: false });
		assert.equal(store.isPageToolbarShown(), false, position);
		assert.equal(store.isAddressVisible(), false, position);
		assert.equal(store.hasPageToolbar(), false, position);
		assert.equal(dataset.address, "hidden", position);
		assert.equal(store.getAddressPlacement(), "page", "the setting stays");
		receive({ event: "toolbarVisibilityChanged", visible: true });
		assert.equal(dataset.address, "page", position);
	}

	store.applyTabLayoutInitialState({ tabPosition: "right", addressPlacement: "page", toolbarVisible: false });
	assert.equal(store.canHideToolbar(), false, "the right's toolbar holds the traffic lights");
	assert.equal(store.isAddressVisible(), true);
});

test("a waiting request temporarily reveals a hidden address", async () => {
	stubBridgeWindow({ document: true });
	stubRoot();
	const load = await freshStores();
	const store = await load("/src/stores/tabLayout.svelte.ts");
	const drawers = await load("/src/stores/urlBarDrawer.svelte.ts");
	drawers.initUrlBarDrawerStore();
	store.applyTabLayoutInitialState({ addressPlacement: "hidden" });

	receive({ event: "agentControlRequested", requestId: "a1", clientName: "Agent", executable: "", profileName: "", action: { kind: "click", label: "Send", site: "example.com", tab: "Inbox" } });
	assert.equal(store.isAddressVisible(), true);

	drawers.respondToPermissionRequest(drawers.getActiveUrlBarDrawer(), false);
	assert.equal(store.isAddressVisible(), false);
	assert.equal(store.getAddressPlacement(), "hidden", "answering keeps the preference");
});

test("a morph to a new edge that never finishes is skipped, so the chrome is never left frozen", async (t) => {
	stubBridgeWindow({ document: true });
	const dataset = stubRoot();
	const doc = (globalThis as unknown as { document: Record<string, unknown> }).document;
	let skipped = 0;
	doc.querySelector = () => null;
	doc.startViewTransition = (update: () => Promise<void>) => {
		void update();
		return { finished: new Promise(() => {}), skipTransition: () => skipped++ };
	};
	(globalThis as { matchMedia?: unknown }).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const store = await (await freshStores())("/src/stores/tabLayout.svelte.ts");
	store.initTabLayoutStore();
	store.applyTabLayoutInitialState({ tabPosition: "left" });

	receive({ event: "tabLayoutChanged", position: "top", address: "tabs" });
	t.mock.timers.tick(999);
	assert.equal(skipped, 0, "the morph gets its time");
	t.mock.timers.tick(1);

	assert.equal(skipped, 1);
	assert.equal(dataset.tabPosition, "top");
});

test("only the new tabs carry the morph's name, while the old ones play out their outro", async () => {
	stubBridgeWindow({ document: true });
	stubRoot();
	const doc = (globalThis as unknown as { document: Record<string, unknown> }).document;
	const old = { style: { viewTransitionName: "" } };
	doc.querySelector = () => old;
	doc.startViewTransition = (update: () => Promise<void>) => ({ finished: update(), skipTransition() {} });
	(globalThis as { matchMedia?: unknown }).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
	const store = await (await freshStores())("/src/stores/tabLayout.svelte.ts");
	store.initTabLayoutStore();
	store.applyTabLayoutInitialState({ tabPosition: "top" });

	receive({ event: "tabLayoutChanged", position: "bottom", address: "page" });
	await new Promise((resolve) => setTimeout(resolve));
	assert.equal(old.style.viewTransitionName, "", "the strip stays and keeps its name");

	receive({ event: "tabLayoutChanged", position: "left", address: "tabs" });
	await new Promise((resolve) => setTimeout(resolve));
	assert.equal(old.style.viewTransitionName, "none");
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
