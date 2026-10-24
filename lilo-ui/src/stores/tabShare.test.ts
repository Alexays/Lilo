import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

test("tab share request opens, resolves with the picked tab, and clears", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");

	store.initTabShareStore();
	receive({ event: "tabSharePickerRequested", requestId: "req-1", origin: "meet.example.com", shareableTabIds: ["tab-beta"] });

	assert.deepEqual(store.getTabShareRequest(), {
		requestId: "req-1",
		origin: "meet.example.com",
		shareableTabIds: new Set(["tab-beta"]),
		allowsSystem: true,
	});

	store.resolveTabShare("tab", "tab-beta");
	assert.deepEqual(posted.at(-1), {
		action: "tabShare.resolve",
		payload: { requestId: "req-1", choice: "tab", tabId: "tab-beta" },
	});
	assert.equal(store.getTabShareRequest(), null);

	// Resolving again is a no-op: nothing pending.
	store.resolveTabShare("cancel");
	assert.equal(posted.at(-1)?.payload.requestId, "req-1");
});

test("system and cancel choices omit tabId", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");

	store.initTabShareStore();
	receive({ event: "tabSharePickerRequested", requestId: "req-1", origin: "meet.example.com", shareableTabIds: ["tab-beta"] });
	store.resolveTabShare("system");
	assert.deepEqual(posted.at(-1), {
		action: "tabShare.resolve",
		payload: { requestId: "req-1", choice: "system" },
	});

	receive({ event: "tabSharePickerRequested", requestId: "req-2", origin: "meet.example.com", shareableTabIds: ["tab-beta"] });
	store.resolveTabShare("cancel");
	assert.deepEqual(posted.at(-1), {
		action: "tabShare.resolve",
		payload: { requestId: "req-2", choice: "cancel" },
	});
});

test("a second request while one is open is cancelled immediately", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");

	store.initTabShareStore();
	receive({ event: "tabSharePickerRequested", requestId: "req-1", origin: "meet.example.com", shareableTabIds: ["tab-beta"] });
	receive({ event: "tabSharePickerRequested", requestId: "req-2", origin: "call.example.org", shareableTabIds: [] });

	assert.deepEqual(posted.at(-1), {
		action: "tabShare.resolve",
		payload: { requestId: "req-2", choice: "cancel" },
	});
	// The first request stays presented.
	assert.deepEqual(store.getTabShareRequest(), {
		requestId: "req-1",
		origin: "meet.example.com",
		shareableTabIds: new Set(["tab-beta"]),
		allowsSystem: true,
	});
});

test("a dismissal from native closes the matching picker only", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");

	store.initTabShareStore();
	receive({ event: "tabSharePickerRequested", requestId: "req-1", origin: "meet.example.com", shareableTabIds: [] });
	receive({ event: "tabSharePickerDismissed", requestId: "req-other" });
	assert.equal(store.getTabShareRequest()?.requestId, "req-1");

	receive({ event: "tabSharePickerDismissed", requestId: "req-1" });
	assert.equal(store.getTabShareRequest(), null);
});

test("an extension offering tabs only hides the system choice", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");

	store.initTabShareStore();
	receive({ event: "tabSharePickerRequested", requestId: "req-1", origin: "Recorder", shareableTabIds: [], allowsSystem: false });

	assert.equal(store.getTabShareRequest()?.allowsSystem, false);
});
