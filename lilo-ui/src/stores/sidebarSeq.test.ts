import assert from "node:assert/strict";
import test, { afterEach } from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload, BridgeTabSnapshot } from "../lib/bridge/protocol";
import { tab, treeItem } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

// ---------------------------------------------------------------------------
// Helper: build a minimal Vite SSR environment with the sidebar store loaded
// ---------------------------------------------------------------------------

const realDateNow = Date.now;
afterEach(() => {
	Date.now = realDateNow;
});

async function makeEnv() {
	const postedMessages = stubBridgeWindow();
	const loadStore = await freshStores();

	const { initTabStore, getTabs, isSpaceHydrated } = await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	const receive = (
		globalThis as {
			window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
		}
	).window.__lilo?.receive;

	/** Freeze Date.now so tests can control throttle windows (restored after each test). */
	function setNow(ts: number) {
		Date.now = () => ts;
	}

	return { applySidebarTabInitialState, getTabs, isSpaceHydrated, receive, postedMessages, setNow };
}

const spaceId = "space-a";

function initialStateWith(tabId: string): BridgeInitialStatePayload {
	return {
		activeSpaceId: spaceId,
		activeTabId: tabId,
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: spaceId,
				name: "Space A",
				icon: "A",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [tab(tabId, spaceId)],
		treeItems: [treeItem(tabId, spaceId, 0)],
	};
}

// ---------------------------------------------------------------------------

test("contiguous stateSeq patches apply normally", async () => {
	const { applySidebarTabInitialState, getTabs, receive } = await makeEnv();
	applySidebarTabInitialState(initialStateWith("tab-a"));

	// Seq 1: add a tab
	receive?.({
		event: "browserStatePatch",
		stateSeq: 1,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-b", spaceId)],
				treeItems: [treeItem("tab-a", spaceId, 0), treeItem("tab-b", spaceId, 1)],
			},
		],
	});
	flushSync();

	// Seq 2: add another tab
	receive?.({
		event: "browserStatePatch",
		stateSeq: 2,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-c", spaceId)],
				treeItems: [
					treeItem("tab-a", spaceId, 0),
					treeItem("tab-b", spaceId, 1),
					treeItem("tab-c", spaceId, 2),
				],
			},
		],
	});
	flushSync();

	assert.deepEqual(
		getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id),
		["tab-a", "tab-b", "tab-c"],
	);
});

// ---------------------------------------------------------------------------

test("a gapped stateSeq patch is discarded and requestBrowserStateSync is posted once for a burst", async () => {
	const { applySidebarTabInitialState, getTabs, receive, postedMessages, setNow } = await makeEnv();
	applySidebarTabInitialState(initialStateWith("tab-a"));

	setNow(1000);

	// Seq 1 arrives first: accepted, and lastStateSeq becomes 1
	receive?.({
		event: "browserStatePatch",
		stateSeq: 1,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-b", spaceId)],
				treeItems: [treeItem("tab-a", spaceId, 0), treeItem("tab-b", spaceId, 1)],
			},
		],
	});
	flushSync();
	assert.deepEqual(
		getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id),
		["tab-a", "tab-b"],
	);

	// Seq 3 skips seq 2 (gap): discarded, and one resync request is posted at t=1000
	receive?.({
		event: "browserStatePatch",
		stateSeq: 3,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-c", spaceId)],
				treeItems: [
					treeItem("tab-a", spaceId, 0),
					treeItem("tab-b", spaceId, 1),
					treeItem("tab-c", spaceId, 2),
				],
			},
		],
	});
	flushSync();

	// tab-c must NOT have been added (patch discarded)
	assert.deepEqual(
		getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id),
		["tab-a", "tab-b"],
	);

	// Exactly one requestBrowserStateSync must have been posted
	const resyncs = postedMessages.filter(
		(m) => m.action === "requestBrowserStateSync",
	);
	assert.equal(resyncs.length, 1);

	// A subsequent gapped patch (seq 4) within the throttle window (t=1100, only 100 ms elapsed)
	// must NOT post another resync: still within the 250 ms burst window.
	setNow(1100);
	receive?.({
		event: "browserStatePatch",
		stateSeq: 4,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-d", spaceId)],
				treeItems: [treeItem("tab-a", spaceId, 0)],
			},
		],
	});
	flushSync();

	const resyncsAfterBurst = postedMessages.filter(
		(m) => m.action === "requestBrowserStateSync",
	);
	assert.equal(resyncsAfterBurst.length, 1, "burst within same throttle window should not post a second resync");
});

// ---------------------------------------------------------------------------

test("a gapped patch arriving after the throttle window re-posts (self-heal of a lost response)", async () => {
	const { applySidebarTabInitialState, getTabs, receive, postedMessages, setNow } = await makeEnv();
	applySidebarTabInitialState(initialStateWith("tab-a"));

	setNow(1000);

	// Seq 1: accepted
	receive?.({
		event: "browserStatePatch",
		stateSeq: 1,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-b", spaceId)],
				treeItems: [treeItem("tab-a", spaceId, 0), treeItem("tab-b", spaceId, 1)],
			},
		],
	});
	flushSync();

	// Seq 3 (gap): posts the first resync at t=1000
	receive?.({
		event: "browserStatePatch",
		stateSeq: 3,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-c", spaceId)],
				treeItems: [],
			},
		],
	});
	flushSync();
	assert.equal(
		postedMessages.filter((m) => m.action === "requestBrowserStateSync").length,
		1,
		"first gap should post exactly one resync",
	);

	// Simulate the full-state response being lost. A new gapped patch arrives after the
	// throttle window (t=1300, 300 ms > 250 ms) and should re-request to self-heal.
	setNow(1300);
	receive?.({
		event: "browserStatePatch",
		stateSeq: 5,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-d", spaceId)],
				treeItems: [],
			},
		],
	});
	flushSync();

	// tab-c and tab-d must NOT be present (patches discarded while resyncPending)
	assert.deepEqual(
		getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id),
		["tab-a", "tab-b"],
	);

	assert.equal(
		postedMessages.filter((m) => m.action === "requestBrowserStateSync").length,
		2,
		"patch after throttle window should trigger a second resync request",
	);

	// A further patch still within the new throttle window (t=1400, 100 ms later) must NOT re-post
	setNow(1400);
	receive?.({
		event: "browserStatePatch",
		stateSeq: 6,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-e", spaceId)],
				treeItems: [],
			},
		],
	});
	flushSync();
	assert.equal(
		postedMessages.filter((m) => m.action === "requestBrowserStateSync").length,
		2,
		"burst within new throttle window should not post a third resync",
	);
});

// ---------------------------------------------------------------------------

test("full state with stateSeq resets tracking and allows contiguous patches again", async () => {
	const { applySidebarTabInitialState, getTabs, receive, postedMessages } = await makeEnv();
	applySidebarTabInitialState(initialStateWith("tab-a"));

	// Trigger a gap so resyncPending latches
	receive?.({
		event: "browserStatePatch",
		stateSeq: 1,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [{ kind: "sidebarChanged", spaceId, activeTabId: "tab-a", treeItems: [] }],
	});
	flushSync();
	receive?.({
		event: "browserStatePatch",
		stateSeq: 99,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [{ kind: "sidebarChanged", spaceId, activeTabId: "tab-a", treeItems: [] }],
	});
	flushSync();
	assert.equal(
		postedMessages.filter((m) => m.action === "requestBrowserStateSync").length,
		1,
	);

	// Full-state resync arrives, stamped with its own seq (e.g. 100)
	receive?.({
		event: "browserStateChanged",
		stateSeq: 100,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		states: [
			{
				spaceId,
				activeTabId: "tab-a",
				tabs: [tab("tab-a", spaceId), tab("tab-b", spaceId)],
				folders: [],
				treeItems: [treeItem("tab-a", spaceId, 0), treeItem("tab-b", spaceId, 1)],
			},
		],
	});
	flushSync();

	// resyncPending cleared, tracking reset to 100
	// Seq 101 should now apply normally
	receive?.({
		event: "browserStatePatch",
		stateSeq: 101,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-c", spaceId)],
				treeItems: [
					treeItem("tab-a", spaceId, 0),
					treeItem("tab-b", spaceId, 1),
					treeItem("tab-c", spaceId, 2),
				],
			},
		],
	});
	flushSync();

	assert.deepEqual(
		getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id),
		["tab-a", "tab-b", "tab-c"],
	);
	// No extra resyncs posted
	assert.equal(
		postedMessages.filter((m) => m.action === "requestBrowserStateSync").length,
		1,
	);
});

// ---------------------------------------------------------------------------

test("sidebarChanged for non-hydrated space posts requestBrowserStateSync and does not apply", async () => {
	const { applySidebarTabInitialState, getTabs, isSpaceHydrated, receive, postedMessages } =
		await makeEnv();

	const otherSpaceId = "space-b";
	applySidebarTabInitialState({
		activeSpaceId: spaceId,
		activeTabId: "tab-a",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: spaceId,
				name: "Space A",
				icon: "A",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: otherSpaceId,
				name: "Space B",
				icon: "B",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		tabs: [tab("tab-a", spaceId)],
		treeItems: [treeItem("tab-a", spaceId, 0)],
	} satisfies BridgeInitialStatePayload);

	// Confirm the other space is not hydrated
	assert.equal(isSpaceHydrated(otherSpaceId), false);

	// A patch for the non-hydrated space should be discarded and trigger a per-space resync,
	// but must NOT touch the global resyncPending latch.
	receive?.({
		event: "browserStatePatch",
		stateSeq: 1,
		changedSpaceId: otherSpaceId,
		activeTabId: "ghost",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId: otherSpaceId,
				activeTabId: "ghost",
				upsertTabs: [tab("ghost", otherSpaceId)],
				treeItems: [treeItem("ghost", otherSpaceId, 0)],
			},
		],
	});
	flushSync();

	// The ghost tab must not have been inserted
	assert.deepEqual(getTabs(otherSpaceId), []);

	// Exactly one resync should have been posted, carrying the spaceId
	const resyncs = postedMessages.filter(
		(m) => m.action === "requestBrowserStateSync",
	);
	assert.equal(resyncs.length, 1);
	assert.equal(resyncs[0].payload.spaceId, otherSpaceId);

	// A contiguous patch for the HYDRATED space (space-a) must still apply normally:
	// the hydration resync for space-b must not latch the global patch channel.
	receive?.({
		event: "browserStatePatch",
		stateSeq: 2,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-b", spaceId)],
				treeItems: [treeItem("tab-a", spaceId, 0), treeItem("tab-b", spaceId, 1)],
			},
		],
	});
	flushSync();

	assert.deepEqual(
		getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id),
		["tab-a", "tab-b"],
		"hydrated-space patch should apply while non-hydrated space resync is pending",
	);

	// A second non-hydrated diff for the SAME space must NOT re-post
	receive?.({
		event: "browserStatePatch",
		stateSeq: 3,
		changedSpaceId: otherSpaceId,
		activeTabId: "ghost2",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId: otherSpaceId,
				activeTabId: "ghost2",
				upsertTabs: [tab("ghost2", otherSpaceId)],
				treeItems: [treeItem("ghost2", otherSpaceId, 0)],
			},
		],
	});
	flushSync();

	assert.equal(
		postedMessages.filter((m) => m.action === "requestBrowserStateSync").length,
		1,
		"second non-hydrated diff for the same space should not re-post",
	);
});

test("an upsert that leaves the favicon out keeps the one held", async () => {
	const { applySidebarTabInitialState, getTabs, receive } = await makeEnv();
	const initial = initialStateWith("tab-a");
	initial.tabs = [tab("tab-a", spaceId, { faviconDataURL: "data:image/png;base64,AAAA" })];
	applySidebarTabInitialState(initial);

	const pinned = tab("tab-a", spaceId, { isPinned: true });
	receive?.({
		event: "browserStatePatch",
		stateSeq: 1,
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [{ kind: "sidebarChanged", spaceId, activeTabId: "tab-a", upsertTabs: [pinned] }],
	});
	flushSync();

	const [updated] = getTabs(spaceId);
	assert.equal(updated.isPinned, true);
	assert.equal(updated.faviconDataURL, "data:image/png;base64,AAAA");
});
