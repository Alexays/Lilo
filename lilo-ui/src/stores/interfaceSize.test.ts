import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

function receive(message: Record<string, unknown>): void {
	(globalThis as unknown as { window: { __lilo: { receive(message: unknown): void } } }).window.__lilo.receive(message);
}

test("interface size restores before the first frame, persists and follows settings from another window", async () => {
	const posted = stubBridgeWindow({ document: true });
	const dataset: Record<string, string> = {};
	Object.assign(document, { documentElement: { dataset } });
	const store = await (await freshStores())("/src/stores/settings.svelte.ts");
	store.applyInterfaceSizeInitialState({ interfaceSize: "roomy" });
	assert.equal(dataset.interfaceSize, "roomy");
	assert.equal(store.getInterfaceSizeStep(), 1);
	assert.equal(posted.length, 0);
	store.initSettingsStore();
	store.setSetting("interfaceSize", "spacious");
	assert.deepEqual(posted.at(-1)?.payload, { key: "interfaceSize", value: "spacious" });
	assert.equal(dataset.interfaceSize, "spacious");
	receive({ event: "settingsLoaded", settings: { interfaceSize: "compact" } });
	assert.equal(dataset.interfaceSize, "compact");
	assert.equal(store.getInterfaceSizeStep(), -1);
	receive({ event: "settingsLoaded", settings: { interfaceSize: "toString" } });
	assert.equal(dataset.interfaceSize, "comfortable");
	receive({ event: "settingsLoaded", settings: {} });
	assert.equal(store.getInterfaceSize(), "comfortable");
	assert.equal(store.getInterfaceSizeStep(), 0);
});
