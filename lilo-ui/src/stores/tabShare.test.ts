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
		suggestedTabIds: [],
		allowsSystem: true,
		audio: null,
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
		suggestedTabIds: [],
		allowsSystem: true,
		audio: null,
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

test("thumbnails are snapshotted one at a time, once each, and dropped with the picker", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");
	const previewRequests = () => posted.filter((message) => message.action === "requestTabPreview").map((message) => message.payload.tabId);

	store.initTabShareStore();
	store.requestTabShareThumbnail("tab-a");
	assert.deepEqual(previewRequests(), [], "nothing is snapshotted without a picker");

	receive({
		event: "tabSharePickerRequested",
		requestId: "req-1",
		origin: "meet.example.com",
		shareableTabIds: ["tab-a", "tab-b"],
		suggestedTabIds: ["tab-b"],
	});
	assert.deepEqual(store.getTabShareRequest()?.suggestedTabIds, ["tab-b"]);
	store.requestTabShareThumbnail("tab-a");
	store.requestTabShareThumbnail("tab-b");
	store.requestTabShareThumbnail("tab-a");
	assert.deepEqual(previewRequests(), ["tab-a"]);

	// The sidebar's hover card shares the reply event: another tab's reply is not ours.
	receive({ event: "tabPreviewReady", tabId: "tab-c", image: "data:image/jpeg;base64,c" });
	assert.equal(store.getTabShareThumbnail("tab-c"), undefined);

	receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,a" });
	assert.equal(store.getTabShareThumbnail("tab-a"), "data:image/jpeg;base64,a");
	assert.deepEqual(previewRequests(), ["tab-a", "tab-b"]);

	receive({ event: "tabPreviewReady", tabId: "tab-b" });
	assert.equal(store.getTabShareThumbnail("tab-b"), "", "a tab without a snapshot is recorded, not asked again");
	store.requestTabShareThumbnail("tab-b");
	assert.deepEqual(previewRequests(), ["tab-a", "tab-b"]);

	store.resolveTabShare("cancel");
	assert.equal(store.getTabShareThumbnail("tab-a"), undefined);
});

test("a page asking for sound gets the screen toggle state; only a window or screen pick carries it", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");
	const audio = { system: "undetermined", systemOn: false };

	store.initTabShareStore();
	receive({ event: "tabSharePickerRequested", requestId: "req-1", origin: "meet.example.com", shareableTabIds: ["tab-a"], audio });
	assert.deepEqual(store.getTabShareRequest()?.audio, audio);

	store.resolveTabShare("system", undefined, true);
	assert.deepEqual(posted.at(-1)?.payload, { requestId: "req-1", choice: "system", audio: true });

	// A tab is shared without sound, as Chrome does with tab audio off.
	receive({ event: "tabSharePickerRequested", requestId: "req-2", origin: "meet.example.com", shareableTabIds: ["tab-a"], audio });
	store.resolveTabShare("tab", "tab-a", true);
	assert.deepEqual(posted.at(-1)?.payload, { requestId: "req-2", choice: "tab", tabId: "tab-a" });
});

test("a page not asking for sound sends no toggle", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabShare.svelte.ts");

	store.initTabShareStore();
	receive({ event: "tabSharePickerRequested", requestId: "req-1", origin: "meet.example.com", shareableTabIds: [] });
	store.resolveTabShare("system", undefined, true);
	assert.deepEqual(posted.at(-1)?.payload, { requestId: "req-1", choice: "system" });
});
