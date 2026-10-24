import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

function copied(captureId: string): void {
	receive({ event: "captureCopied", captureId, thumbURL: `lilo-chrome://ui/screenshot/${captureId}.png`, filename: `${captureId}.png` });
}

async function setup() {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/captureCard.svelte.ts");
	store.initCaptureCardStore();
	return { store, posted };
}

test("the card stays 6 s, hover pauses with the remaining time, and its capture is released", async () => {
	const { store, posted } = await setup();
	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		copied("c1");
		mock.timers.tick(4000);
		store.pauseCaptureCard();
		mock.timers.tick(10_000);
		assert.notEqual(store.getCaptureCard(), null, "paused under the pointer");
		store.resumeCaptureCard();
		mock.timers.tick(1999);
		assert.notEqual(store.getCaptureCard(), null);
		mock.timers.tick(1);
		assert.equal(store.getCaptureCard(), null);
		assert.deepEqual(posted.filter((m) => m.action === "releaseCapture").map((m) => m.payload.captureId), ["c1"]);
	} finally {
		mock.timers.reset();
	}
});

test("a copied capture replaced by another is released", async () => {
	const { store, posted } = await setup();
	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		copied("c1");
		copied("c2");

		assert.equal(store.getCaptureCard()?.captureId, "c2");
		assert.deepEqual(posted.filter((m) => m.action === "releaseCapture").map((m) => m.payload.captureId), ["c1"]);
	} finally {
		mock.timers.reset();
	}
});

test("Edit hands the capture to the editor and the card goes without releasing it", async () => {
	const { store, posted } = await setup();
	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		copied("c1");
		store.editCapture();

		assert.equal(store.getCaptureCard(), null);
		assert.deepEqual(posted.find((m) => m.action === "editCapture")?.payload, { captureId: "c1" });
		mock.timers.tick(10_000);
		assert.equal(posted.some((m) => m.action === "releaseCapture"), false);
	} finally {
		mock.timers.reset();
	}
});

test("Save writes the capture under its name before releasing it", async () => {
	const { store, posted } = await setup();
	copied("c1");
	store.saveCapture();

	assert.equal(store.getCaptureCard(), null);
	assert.deepEqual(
		posted.map((m) => [m.action, m.payload]),
		[
			["screenshot.saveDefault", { id: "c1", filename: "c1.png" }],
			["releaseCapture", { captureId: "c1" }],
		],
	);
});
