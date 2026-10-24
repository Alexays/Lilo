import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

function settings(pinnedExtensions: string): void {
	receive({ event: "settingsLoaded", settings: { pinnedExtensions } });
}

function installed(...ids: string[]): void {
	receive({ event: "extensionsChanged", ids, extensions: ids.map((id) => ({ id })) });
}

async function loadPinsStore() {
	const loadStore = await freshStores();
	const extensions = await loadStore("/src/stores/extensions.svelte.ts");
	extensions.initExtensionStore();
	const store = await loadStore("/src/stores/extensionPins.svelte.ts");
	store.initExtensionPinsStore();
	installed("alpha", "beta", "gamma", "delta", "a", "b", "c", "d", "e");
	return store;
}

test("the pinned list comes from the settings snapshot", async () => {
	stubBridgeWindow();
	const store = await loadPinsStore();

	assert.deepEqual(store.getPinnedExtensionIds(), []);
	settings("alpha, beta");
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha", "beta"]);
	assert.equal(store.isExtensionPinned("beta"), true);
	assert.equal(store.isExtensionPinned("gamma"), false);
});

test("uninstalled ids never show, and drop on the next write", async () => {
	const posted = stubBridgeWindow();
	const store = await loadPinsStore();

	settings("alpha,gone,beta");
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha", "beta"]);

	store.toggleExtensionPin("gamma");
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha", "beta", "gamma"]);
	assert.deepEqual(posted.at(-1), {
		action: "setSetting",
		payload: { key: "pinnedExtensions", value: "alpha,beta,gamma" },
	});

	installed("alpha", "gamma");
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha", "gamma"]);
});

test("toggling pins persists the list in pin order, with no cap", async () => {
	const posted = stubBridgeWindow();
	const store = await loadPinsStore();

	store.toggleExtensionPin("alpha");
	assert.deepEqual(posted.at(-1), {
		action: "setSetting",
		payload: { key: "pinnedExtensions", value: "alpha" },
	});

	for (const id of ["beta", "gamma", "delta", "a", "b"]) store.toggleExtensionPin(id);
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha", "beta", "gamma", "delta", "a", "b"]);
	assert.deepEqual(posted.at(-1), {
		action: "setSetting",
		payload: { key: "pinnedExtensions", value: "alpha,beta,gamma,delta,a,b" },
	});

	store.toggleExtensionPin("beta");
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha", "gamma", "delta", "a", "b"]);
});

test("pinning an already pinned extension changes nothing", async () => {
	const posted = stubBridgeWindow();
	const store = await loadPinsStore();

	store.pinExtension("alpha");
	store.pinExtension("beta");
	const writes = posted.length;
	store.pinExtension("alpha");
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha", "beta"]);
	assert.equal(posted.length, writes);
});

test("a long stored list is kept whole, in its order", async () => {
	stubBridgeWindow();
	const store = await loadPinsStore();

	settings("e,a,d,b,c");
	assert.deepEqual(store.getPinnedExtensionIds(), ["e", "a", "d", "b", "c"]);
});

test("the native context menu's pin item toggles the pin", async () => {
	stubBridgeWindow();
	const store = await loadPinsStore();

	receive({ event: "extensionMenuAction", id: "alpha", action: "togglePin" });
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha"]);
	receive({ event: "extensionMenuAction", id: "alpha", action: "details" });
	assert.deepEqual(store.getPinnedExtensionIds(), ["alpha"]);
	receive({ event: "extensionMenuAction", id: "alpha", action: "togglePin" });
	assert.deepEqual(store.getPinnedExtensionIds(), []);
});
