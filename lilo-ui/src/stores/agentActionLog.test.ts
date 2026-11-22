import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } };

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

async function loadStore() {
	const loadStores = await freshStores();
	return loadStores("/src/stores/agentActionLog.svelte.ts");
}

test("nothing is read or asked for until the page asks", async () => {
	const posted = stubBridgeWindow();
	const store = await loadStore();
	assert.equal(store.getAgentActionLog(), null);
	assert.deepEqual(posted.filter((m) => m.action === "getAgentActionLog"), []);
});

test("loading asks native once per call and keeps the answer as it came", async () => {
	const posted = stubBridgeWindow();
	const store = await loadStore();

	store.loadAgentActionLog();
	assert.equal(posted.filter((m) => m.action === "getAgentActionLog").length, 1);

	const clients = [{ name: "Claude Code", calls: [{ time: "2026-01-02T03:04:05.000Z", tool: "navigate", host: "example.com", ok: true, code: null }] }];
	receive({ event: "agentActionLog", clients });
	assert.deepEqual(store.getAgentActionLog(), clients);

	receive({ event: "agentActionLog", clients: [] });
	assert.deepEqual(store.getAgentActionLog(), []);
});

test("Open Action Log posts the reveal and nothing else", async () => {
	const posted = stubBridgeWindow();
	const store = await loadStore();
	store.openAgentActionLog();
	assert.deepEqual(posted.filter((m) => m.action === "openAgentActionLog").length, 1);
	assert.equal(posted.filter((m) => m.action === "getAgentActionLog").length, 0);
});
