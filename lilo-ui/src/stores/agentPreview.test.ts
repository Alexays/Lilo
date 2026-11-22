import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } };

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

const preview = (client: string, remove = false) => ({
	event: "agentClientPreview",
	client,
	remove,
	path: "~/.cursor/mcp.json",
	command: null,
	lines: [{ number: 2, removed: false, text: '"lilo": {}' }],
	snippet: "{}",
	blocked: null,
});

async function loadSettings() {
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/settings.svelte.ts");
	store.initSettingsStore();
	return store;
}

test("Connect asks native what it will write and opens the sheet on the answer", async () => {
	const posted = stubBridgeWindow();
	const store = await loadSettings();

	store.previewAgentClient("cursor");
	assert.deepEqual(posted.filter((m) => m.action === "previewAgentClient").map((m) => m.payload), [{ client: "cursor", remove: false }]);
	assert.equal(store.getAgentPreview(), null, "nothing opens before native answered");

	receive(preview("cursor"));
	assert.equal(store.getAgentPreview()?.path, "~/.cursor/mcp.json");
});

test("an answer for an app the user did not ask about is dropped", async () => {
	stubBridgeWindow();
	const store = await loadSettings();

	store.previewAgentClient("cursor");
	receive(preview("codex"));
	assert.equal(store.getAgentPreview(), null);
});

test("Remove asks for the removal preview, and the sheet closes once native has written", async () => {
	const posted = stubBridgeWindow();
	const store = await loadSettings();

	store.previewAgentClient("cursor", true);
	receive(preview("cursor", true));
	assert.equal(store.getAgentPreview()?.remove, true);
	assert.deepEqual(posted.filter((m) => m.action === "previewAgentClient").map((m) => m.payload), [{ client: "cursor", remove: true }]);

	store.removeAgentClient("cursor");
	store.removeAgentClient("cursor");
	assert.equal(posted.filter((m) => m.action === "removeAgentClient").length, 1, "a second click while it works does nothing");
	assert.equal(store.isConnectingAgentClient("cursor"), true);

	receive({ event: "settingsActionCompleted", action: "connectAgentClient", message: "Removed", level: "info" });
	assert.equal(store.getAgentPreview(), null);
	assert.equal(store.isConnectingAgentClient("cursor"), false);
});

test("Cancel closes the sheet and writes nothing", async () => {
	const posted = stubBridgeWindow();
	const store = await loadSettings();

	store.previewAgentClient("cursor");
	receive(preview("cursor"));
	store.closeAgentPreview();

	assert.equal(store.getAgentPreview(), null);
	assert.equal(posted.filter((m) => m.action === "connectAgentClient" || m.action === "removeAgentClient").length, 0);
});
