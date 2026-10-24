import assert from "node:assert/strict";
import test, { afterEach, mock } from "node:test";
import { tab } from "./testFixtures";
import { freshStores, stubBridgeWindow, type PostedMessage } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

function hang(tabId: string, host: string, site = host): void {
	receive({ event: "pageResponsivenessChanged", tabId, responsive: false, host, site });
}

function recover(tabId: string): void {
	receive({ event: "pageResponsivenessChanged", tabId, responsive: true, host: "", site: "" });
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- test modules are untyped
type StoreModule = Record<string, any>;

async function load(): Promise<{ store: StoreModule; posted: PostedMessage[]; undoToast: StoreModule }> {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/pageHang.svelte.ts");
	store.initPageHangStore();
	const undoToast = await loadStore("/src/stores/undoToast.svelte.ts");
	(await loadStore("/src/stores/sidebar.svelte.ts")).initSidebarStore();
	// After loading: the dev server must not run on mocked clocks. Mocked, a hang left open holds no real interval.
	mock.timers.enable({ apis: ["setInterval", "setTimeout", "Date"], now: 0 });
	return { store, posted, undoToast };
}

afterEach(() => mock.timers.reset());

test("a hung tab shows the card with a live counter, and it goes when the page answers", async () => {
	const { store } = await load();
	hang("t1", "shop.example.com", "example.com");

	assert.equal(store.getShownPageHang("t1")?.host, "shop.example.com");
	assert.equal(store.getShownPageHang("t1")?.repeat, false);
	assert.equal(store.getHangSeconds("t1"), 0);
	assert.equal(store.getHangSeconds("t2"), null);
	mock.timers.tick(12_000);
	assert.equal(store.getHangSeconds("t1"), 12);

	recover("t1");
	assert.equal(store.getShownPageHang("t1"), undefined);
	assert.equal(store.getHangSeconds("t1"), null);
	assert.equal(store.getRecoveredPage(), null, "a page that answers by itself shows no toast");
});

test("Wait hides the card, which comes back if the page is still stuck 10 s later", async () => {
	const { store } = await load();
	hang("t1", "example.com");

	store.waitForHungPage("t1");
	assert.equal(store.getShownPageHang("t1"), undefined);
	assert.equal(store.getHangSeconds("t1"), 0, "the sidebar keeps counting");
	mock.timers.tick(9_000);
	assert.equal(store.getShownPageHang("t1"), undefined);
	mock.timers.tick(1_000);
	assert.equal(store.getShownPageHang("t1")?.host, "example.com");
});

test("Reload hides the card, reloads, and the page answering again is reported for the toast", async () => {
	const { store, posted } = await load();
	hang("t1", "example.com");

	store.reloadHungPage("t1");

	assert.equal(store.getShownPageHang("t1"), undefined);
	assert.notEqual(store.getHangSeconds("t1"), null, "still hung until the page answers");
	assert.deepEqual(posted.at(-1), { action: "reload", payload: {} });
	recover("t1");
	assert.deepEqual(store.getRecoveredPage(), { tabId: "t1", seq: 1 });
});

test("hanging again on the same site after a reload is a repeat", async () => {
	const { store } = await load();
	hang("t1", "www.example.com", "example.com");
	store.reloadHungPage("t1");
	recover("t1");

	hang("t1", "shop.example.com", "example.com");

	assert.equal(store.getShownPageHang("t1")?.repeat, true);
	assert.equal(store.getPageHang("t1")?.repeat, true);
});

test("a hang on another site resets the repeat", async () => {
	const { store } = await load();
	hang("t1", "example.com");
	store.reloadHungPage("t1");
	recover("t1");

	hang("t2", "other.org");
	assert.equal(store.getShownPageHang("t2")?.repeat, false);
	recover("t2");
	hang("t1", "example.com");

	assert.equal(store.getShownPageHang("t1")?.repeat, false);
});

test("a hang without a reload before it is no repeat", async () => {
	const { store } = await load();
	hang("t1", "example.com");
	recover("t1");

	hang("t1", "example.com");

	assert.equal(store.getShownPageHang("t1")?.repeat, false);
});

test("reloading without the blocker allows the site, offers to undo it, and reloads", async () => {
	const { store, posted, undoToast } = await load();
	hang("t1", "example.com");

	store.reloadHungPageWithoutBlocker("t1");

	assert.deepEqual(
		posted.map((message) => [message.action, message.payload]),
		[["toggleBlockerAllowlist", { host: "example.com" }], ["reload", {}]],
	);
	assert.match(undoToast.getUndoToast()?.label ?? "", /example\.com/);
	undoToast.undoTabClose();
	assert.deepEqual(posted.at(-1), { action: "toggleBlockerAllowlist", payload: { host: "example.com" } });
	assert.equal(undoToast.getUndoToast(), null);
});

test("Close Tab closes the hung tab", async () => {
	const { store, posted } = await load();
	hang("t1", "example.com");

	store.closeHungTab("t1");

	assert.deepEqual(posted.at(-1), { action: "closeTab", payload: { id: "t1" } });
	assert.equal(store.getHangSeconds("t1"), null);
});

test("a hung tab closed from elsewhere is dropped", async () => {
	const { store } = await load();
	receive({
		event: "browserStateChanged",
		changedSpaceId: "s1",
		states: [{ spaceId: "s1", activeTabId: "t1", tabs: [tab("t1", "s1"), tab("t2", "s1")], folders: [], treeItems: [] }],
	});
	hang("t1", "example.com");

	receive({
		event: "browserStatePatch",
		operations: [{ kind: "sidebarChanged", spaceId: "s1", activeTabId: "t2", removedTabIds: ["t1"] }],
	});

	assert.equal(store.getPageHang("t1"), undefined);
});
