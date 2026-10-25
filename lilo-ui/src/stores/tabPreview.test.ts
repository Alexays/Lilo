import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { freshStores, stubBridgeWindow, type PostedMessage } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

function previewRequests(posted: PostedMessage[]): PostedMessage[] {
	return posted.filter((m) => m.action === "requestTabPreview");
}

const anchor = { top: 100, right: 260, bottom: 132, left: 10 };

function target(id: string, url = `https://example.com/${id}`) {
	return { id, title: id, url };
}

test("hover requests a preview after the delay; leaving first cancels it", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(449);
		assert.equal(previewRequests(posted).length, 0, "no request before the delay");
		mock.timers.tick(1);
		assert.deepEqual(previewRequests(posted).at(-1)?.payload, { tabId: "tab-a" });

		receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,AAA" });
		assert.deepEqual(store.getTabPreview(), {
			tabId: "tab-a",
			title: "tab-a",
			url: "https://example.com/tab-a",
			favicon: "",
			image: "data:image/jpeg;base64,AAA",
			terminal: null,
			anchor,
		});

		store.clearTabPreview();
		assert.equal(store.getTabPreview(), null);

		// A hover abandoned before the delay never posts.
		store.hoverTabPreview(target("tab-b"), anchor);
		mock.timers.tick(200);
		store.clearTabPreview();
		mock.timers.tick(10_000);
		assert.equal(previewRequests(posted).length, 1);
	} finally {
		mock.timers.reset();
	}
});

test("only one request is in flight; the next hover waits for the reply", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(450);
		assert.equal(previewRequests(posted).length, 1);

		store.clearTabPreview();
		store.hoverTabPreview(target("tab-b"), anchor);
		mock.timers.tick(450);
		assert.equal(previewRequests(posted).length, 1, "tab-b waits for tab-a's reply");

		receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,AAA" });
		assert.deepEqual(previewRequests(posted).at(-1)?.payload, { tabId: "tab-b" });
		// tab-a's reply must not surface while tab-b is the hovered row.
		assert.equal(store.getTabPreview(), null);

		receive({ event: "tabPreviewReady", tabId: "tab-b", image: "data:image/jpeg;base64,BBB" });
		assert.equal(store.getTabPreview()?.tabId, "tab-b");
	} finally {
		mock.timers.reset();
	}
});

test("a request whose reply never arrives stops blocking later hovers", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(450);
		assert.equal(previewRequests(posted).length, 1);

		store.clearTabPreview();
		store.hoverTabPreview(target("tab-b"), anchor);
		mock.timers.tick(450);
		assert.equal(previewRequests(posted).length, 1, "tab-b waits while tab-a's request is fresh");

		// The held hover's refresh ticks retry once tab-a's request has expired.
		mock.timers.tick(3_100);
		assert.deepEqual(previewRequests(posted).at(-1)?.payload, { tabId: "tab-b" });
	} finally {
		mock.timers.reset();
	}
});

test("re-hovering within the TTL reuses the cache; expiry and URL change re-request", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(450);
		receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,AAA" });
		store.clearTabPreview();

		// Within the TTL: the cached image shows instantly, and an aged entry triggers a
		// background refresh (stale-while-revalidate) whose reply swaps the visible image.
		mock.timers.tick(10_000);
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(450);
		assert.equal(store.getTabPreview()?.image, "data:image/jpeg;base64,AAA");
		assert.equal(previewRequests(posted).length, 2);
		receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,AA2" });
		assert.equal(store.getTabPreview()?.image, "data:image/jpeg;base64,AA2");
		store.clearTabPreview();

		// The tab navigated: the cached entry is stale even within the TTL.
		store.hoverTabPreview(target("tab-a", "https://example.com/elsewhere"), anchor);
		mock.timers.tick(450);
		assert.equal(previewRequests(posted).length, 3);
		receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,BBB" });
		store.clearTabPreview();

		// Past the TTL: re-request.
		mock.timers.tick(31_000);
		store.hoverTabPreview(target("tab-a", "https://example.com/elsewhere"), anchor);
		mock.timers.tick(450);
		assert.equal(previewRequests(posted).length, 4);
	} finally {
		mock.timers.reset();
	}
});

test("a held hover refreshes after the first cadence, then backs off", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(450);
		receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,AAA" });
		assert.equal(previewRequests(posted).length, 1);

		mock.timers.tick(1000);
		assert.equal(previewRequests(posted).length, 2, "first refresh after 1s");
		receive({ event: "tabPreviewReady", tabId: "tab-a", image: "data:image/jpeg;base64,AA2" });

		mock.timers.tick(2000);
		assert.equal(previewRequests(posted).length, 3, "second refresh after 2s");
	} finally {
		mock.timers.reset();
	}
});

test("an absent image is cached as 'no preview': nothing shows and no re-request loop", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(450);
		receive({ event: "tabPreviewReady", tabId: "tab-a" });
		assert.equal(store.getTabPreview(), null);
		assert.equal(previewRequests(posted).length, 1);

		store.clearTabPreview();
		store.hoverTabPreview(target("tab-a"), anchor);
		mock.timers.tick(450);
		assert.equal(previewRequests(posted).length, 1, "the miss is cached for the TTL");
	} finally {
		mock.timers.reset();
	}
});

test("a terminal waiting on a menu shows it and stays up while the pointer crosses to the card", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("term", ""), anchor);
		mock.timers.tick(450);
		const menu = {
			lines: ["Do you want to proceed?", "1. Yes", "2. No"],
			question: "Do you want to proceed?",
			choices: [{ key: "1", label: "Yes" }, { key: "2", label: "No" }],
		};
		receive({ event: "tabPreviewReady", tabId: "term", ...menu });
		assert.deepEqual(store.getTabPreview()?.terminal, menu);

		store.leaveTabPreview();
		mock.timers.tick(200);
		store.holdTabPreview();
		mock.timers.tick(1_000);
		assert.ok(store.getTabPreview(), "reaching the card keeps it up");

		store.leaveTabPreview();
		mock.timers.tick(250);
		assert.equal(store.getTabPreview(), null, "leaving without reaching the card hides it");
	} finally {
		mock.timers.reset();
	}
});

test("a terminal with nothing to answer hides as soon as the pointer leaves its row", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/tabPreview.svelte.ts");

	mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
	try {
		store.hoverTabPreview(target("term", ""), anchor);
		mock.timers.tick(450);
		receive({ event: "tabPreviewReady", tabId: "term", lines: ["$ make", "Build complete"], question: "", choices: [] });
		assert.deepEqual(store.getTabPreview()?.terminal?.lines, ["$ make", "Build complete"]);

		store.leaveTabPreview();
		assert.equal(store.getTabPreview(), null);
	} finally {
		mock.timers.reset();
	}
});
