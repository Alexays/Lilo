import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

function closeTab(title: string, count?: number): void {
	receive({ event: "tabClosedUndoable", title, count });
}

test("a close shows the toast; it auto-dismisses after 5s", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/undoToast.svelte.ts");
	store.initUndoToastStore();

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		closeTab("Alpha Docs");
		assert.deepEqual(store.getUndoToast(), { title: "Alpha Docs", count: 1, seq: 1 });
		mock.timers.tick(4999);
		assert.notEqual(store.getUndoToast(), null);
		mock.timers.tick(1);
		assert.equal(store.getUndoToast(), null);
	} finally {
		mock.timers.reset();
	}
});

test("a second close replaces the toast and resets the timer", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/undoToast.svelte.ts");
	store.initUndoToastStore();

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		closeTab("Alpha Docs");
		mock.timers.tick(4000);
		closeTab("Beta Mail");
		assert.deepEqual(store.getUndoToast(), { title: "Beta Mail", count: 1, seq: 2 });
		mock.timers.tick(4999);
		assert.notEqual(store.getUndoToast(), null, "the replacement restarts the 5s window");
		mock.timers.tick(1);
		assert.equal(store.getUndoToast(), null);
	} finally {
		mock.timers.reset();
	}
});

test("hover pauses the timer and leaving resumes with the remainder", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/undoToast.svelte.ts");
	store.initUndoToastStore();

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		closeTab("Alpha Docs");
		mock.timers.tick(3000);
		store.pauseUndoToast();
		mock.timers.tick(60_000);
		assert.notEqual(store.getUndoToast(), null, "paused toast never dismisses");
		store.resumeUndoToast();
		mock.timers.tick(1999);
		assert.notEqual(store.getUndoToast(), null);
		mock.timers.tick(1);
		assert.equal(store.getUndoToast(), null);
	} finally {
		mock.timers.reset();
	}
});

test("a close while hovered replaces the toast but keeps it paused", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/undoToast.svelte.ts");
	store.initUndoToastStore();

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		closeTab("Alpha Docs");
		store.pauseUndoToast();
		closeTab("Beta Mail");
		assert.deepEqual(store.getUndoToast(), { title: "Beta Mail", count: 1, seq: 2 });
		mock.timers.tick(60_000);
		assert.notEqual(store.getUndoToast(), null, "still paused after the replacement");
		store.resumeUndoToast();
		mock.timers.tick(4999);
		assert.notEqual(store.getUndoToast(), null, "resume gets the full window");
		mock.timers.tick(1);
		assert.equal(store.getUndoToast(), null);
	} finally {
		mock.timers.reset();
	}
});

test("undo posts restoreClosedTab and dismisses", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/undoToast.svelte.ts");
	store.initUndoToastStore();

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		closeTab("Alpha Docs");
		store.undoTabClose();
		assert.deepEqual(posted.at(-1), { action: "restoreClosedTab", payload: {} });
		assert.equal(store.getUndoToast(), null);
		// The dead timer must not act on a later toast.
		closeTab("Beta Mail");
		mock.timers.tick(4999);
		assert.notEqual(store.getUndoToast(), null);
	} finally {
		mock.timers.reset();
	}
});

test("undo of a batch close posts one restoreClosedTab per closed tab", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/undoToast.svelte.ts");
	store.initUndoToastStore();

	closeTab("", 3);
	assert.deepEqual(store.getUndoToast(), { title: "", count: 3, seq: 1 });
	const before = posted.length;
	store.undoTabClose();
	assert.deepEqual(
		posted.slice(before),
		Array.from({ length: 3 }, () => ({ action: "restoreClosedTab", payload: {} })),
	);
	assert.equal(store.getUndoToast(), null);
});

test("undo of a Clear brings its tabs back from the archive in one request", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/undoToast.svelte.ts");
	store.initUndoToastStore();

	receive({ event: "tabClosedUndoable", title: "", count: 2, archivedIds: ["a", "b"] });
	const before = posted.length;
	store.undoTabClose();
	assert.deepEqual(posted.slice(before), [{ action: "restoreArchivedTabs", payload: { ids: ["a", "b"] } }]);
	assert.equal(store.getUndoToast(), null);
});
