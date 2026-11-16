import { strict as assert } from "node:assert";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

function receive(settings: Record<string, string>): void {
	(globalThis as unknown as { window: { __lilo: { receive(message: unknown): void } } }).window.__lilo.receive({ event: "settingsLoaded", settings });
}

test("interface style restores before first paint, persists and syncs between windows", async () => {
	const posted = stubBridgeWindow({ document: true });
	const dataset: Record<string, string> = {};
	Object.assign(document, { documentElement: { dataset } });
	const store = await (await freshStores())("/src/stores/settings.svelte.ts");
	store.applyInterfaceStyleInitialState({ interfaceStyle: "streamlined" });
	assert.equal(dataset.interfaceStyle, "streamlined");
	assert.equal(store.getSidebarRowHeight(), 36);
	assert.equal(store.getInterfaceTextSize(), 14);
	assert.equal(posted.length, 0);
	store.initSettingsStore();
	store.setSetting("interfaceStyle", "default");
	assert.deepEqual(posted.at(-1)?.payload, { key: "interfaceStyle", value: "default" });
	assert.equal(dataset.interfaceStyle, "default");
	assert.equal(store.getSidebarRowHeight(), 32);
	assert.equal(store.getInterfaceTextSize(), 13);
	receive({ interfaceStyle: "streamlined" });
	assert.equal(dataset.interfaceStyle, "streamlined");
	receive({ interfaceStyle: "toString" });
	assert.equal(dataset.interfaceStyle, "default");
	receive({});
	assert.equal(store.getInterfaceStyle(), "default");
});
