import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

test("a restart the quit cancelled offers the restart again", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/settings.svelte.ts");
	store.initSettingsStore();
	receive({ event: "updateReady", version: "2.0.0" });

	store.restartForUpdate();
	assert.equal(store.isRestartingForUpdate(), true);
	store.restartForUpdate();
	assert.equal(posted.filter((m) => m.action === "installUpdate").length, 1, "one install per click until it settles");

	receive({ event: "updateReady", version: "2.0.0" });
	assert.equal(store.isRestartingForUpdate(), false);
	assert.equal(store.getReadyUpdate(), "2.0.0");
});
