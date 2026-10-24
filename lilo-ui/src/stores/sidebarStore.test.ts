import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload, BridgeTabSnapshot } from "../lib/bridge/protocol";
import { tab, treeItem } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("sidebarChanged patch reaches the same getter state as a full replace (pin scenario)", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const tabsModule = await loadStore("/src/stores/tabs.svelte.ts");
	const foldersModule = await loadStore("/src/stores/folders.svelte.ts");
	const { getTabs, getActiveTabId, initTabStore } = tabsModule;
	const { getRootItems } = foldersModule;
	const { applySidebarFolderInitialState, applySidebarTabInitialState, getSpaceSidebar } =
		await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	const spaceId = "space";
	const initial = {
		activeSpaceId: spaceId,
		activeTabId: "tab-a",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: spaceId,
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [tab("tab-a", spaceId), tab("tab-b", spaceId)],
		treeItems: [],
	} satisfies BridgeInitialStatePayload;

	const receive = (
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
	).window.__lilo?.receive;

	const initialTree = [
		treeItem("tab-a", spaceId, 0),
		treeItem("tab-b", spaceId, 1),
	];
	const pinnedTree = [
		treeItem("tab-a", spaceId, 0, "pinned"),
		treeItem("tab-b", spaceId, 0),
	];
	const snapshotGetters = () => ({
		tabs: getTabs(spaceId).map((t: BridgeTabSnapshot) => [t.id, t.isPinned]),
		pinnedRoots: getRootItems(spaceId, true),
		unpinnedRoots: getRootItems(spaceId, false),
		treeItemIds: getSpaceSidebar(spaceId).treeItems.map((item: { itemId: string }) => item.itemId),
		activeTabId: getActiveTabId(spaceId),
	});

	// Path 1: full replace describing the post-pin state.
	applySidebarTabInitialState(initial);
	applySidebarFolderInitialState({ ...initial, treeItems: initialTree });
	receive?.({
		event: "browserStateChanged",
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		states: [
			{
				spaceId,
				activeTabId: "tab-a",
				tabs: [tab("tab-a", spaceId, { isPinned: true }), tab("tab-b", spaceId)],
				folders: [],
				treeItems: pinnedTree,
			},
		],
	});
	flushSync();
	const fullReplaceResult = snapshotGetters();

	// Path 2: same starting point, then the structural diff patch.
	applySidebarTabInitialState(initial);
	applySidebarFolderInitialState({ ...initial, treeItems: initialTree });
	receive?.({
		event: "browserStatePatch",
		changedSpaceId: spaceId,
		activeTabId: "tab-a",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-a",
				upsertTabs: [tab("tab-a", spaceId, { isPinned: true })],
				treeItems: pinnedTree,
			},
		],
	});
	flushSync();
	const patchResult = snapshotGetters();

	assert.deepEqual(patchResult, fullReplaceResult);
	assert.deepEqual(patchResult.pinnedRoots, [{ kind: "tab", id: "tab-a" }]);
	assert.deepEqual(patchResult.unpinnedRoots, [{ kind: "tab", id: "tab-b" }]);
});

test("sidebarChanged removes tabs and folders and is ignored for non-hydrated spaces", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getTabs, initTabStore, isSpaceHydrated } = await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarFolderInitialState, applySidebarTabInitialState, getSpaceSidebar } =
		await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	const spaceId = "space";
	const initial = {
		activeSpaceId: spaceId,
		activeTabId: "tab-a",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: spaceId,
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: "other-space",
				name: "Other",
				icon: "O",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		tabs: [tab("tab-a", spaceId), tab("tab-b", spaceId)],
		treeItems: [treeItem("tab-a", spaceId, 0), treeItem("tab-b", spaceId, 1)],
	} satisfies BridgeInitialStatePayload;
	applySidebarTabInitialState(initial);
	applySidebarFolderInitialState(initial);

	const receive = (
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
	).window.__lilo?.receive;

	// Removal in the hydrated space applies.
	receive?.({
		event: "browserStatePatch",
		changedSpaceId: spaceId,
		activeTabId: "tab-b",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-b",
				removedTabIds: ["tab-a"],
				treeItems: [treeItem("tab-b", spaceId, 0)],
			},
		],
	});
	flushSync();
	assert.deepEqual(
		getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id),
		["tab-b"],
	);

	// A diff against a non-hydrated space must be ignored (fullState resyncs on switch).
	assert.equal(isSpaceHydrated("other-space"), false);
	receive?.({
		event: "browserStatePatch",
		changedSpaceId: "other-space",
		activeTabId: "ghost",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId: "other-space",
				activeTabId: "ghost",
				upsertTabs: [tab("ghost", "other-space")],
				treeItems: [treeItem("ghost", "other-space", 0)],
			},
		],
	});
	flushSync();
	assert.deepEqual(getTabs("other-space"), []);
	assert.deepEqual(getSpaceSidebar("other-space").treeItems, []);
});

test("sidebarChanged tree deltas patch the held tree by itemId", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const { getTabs, initTabStore } = await loadStore("/src/stores/tabs.svelte.ts");
	const { getRootItems } = await loadStore("/src/stores/folders.svelte.ts");
	const { applySidebarFolderInitialState, applySidebarTabInitialState, getSpaceSidebar } =
		await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	const spaceId = "space";
	const initial = {
		activeSpaceId: spaceId,
		activeTabId: "tab-a",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "Space", icon: "S", color: "#5865f2", profileId: "profile", isPrivate: false, sortOrder: 0 }],
		tabs: [tab("tab-a", spaceId), tab("tab-b", spaceId), tab("tab-c", spaceId)],
		treeItems: [treeItem("tab-a", spaceId, 0), treeItem("tab-b", spaceId, 1), treeItem("tab-c", spaceId, 2)],
	} satisfies BridgeInitialStatePayload;
	applySidebarTabInitialState(initial);
	applySidebarFolderInitialState(initial);
	const receive = (globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }).window.__lilo?.receive;

	// tab-b closes, tab-c moves up, tab-d opens last; the host's item ids are fresh.
	receive?.({
		event: "browserStatePatch",
		changedSpaceId: spaceId,
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "tab-d",
				removedTabIds: ["tab-b"],
				upsertTabs: [tab("tab-d", spaceId)],
				removedTreeItemIds: ["tab-b"],
				upsertTreeItems: [
					{ ...treeItem("tab-c", spaceId, 1), id: "fresh-c" },
					{ ...treeItem("tab-d", spaceId, 2), id: "fresh-d" },
				],
			},
		],
	});
	flushSync();

	assert.deepEqual(getTabs(spaceId).map((t: BridgeTabSnapshot) => t.id), ["tab-a", "tab-c", "tab-d"]);
	assert.deepEqual(getRootItems(spaceId, false).map((item: { id: string }) => item.id), ["tab-a", "tab-c", "tab-d"]);
	assert.equal(getSpaceSidebar(spaceId).treeItems.length, 3);
});

// ---------------------------------------------------------------------------
// Helpers shared by the optimistic-activation and view-reuse tests
// ---------------------------------------------------------------------------

async function makeSidebarEnv() {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const sidebarMod = await loadStore("/src/stores/sidebar.svelte.ts");
	const tabsMod = await loadStore("/src/stores/tabs.svelte.ts");

	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar } = sidebarMod;
	const { getActiveTabId, initTabStore } = tabsMod;
	initTabStore();

	const receive = (
		globalThis as {
			window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
		}
	).window.__lilo?.receive;

	return { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar, getActiveTabId, receive };
}

const sidebarSpaceId = "space-x";

function sidebarInitialState(tabs: BridgeTabSnapshot[], activeTabId: string): BridgeInitialStatePayload {
	return {
		activeSpaceId: sidebarSpaceId,
		activeTabId,
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: sidebarSpaceId, name: "X", icon: "X", color: "#000", profileId: "p", isPrivate: false, sortOrder: 0 }],
		tabs,
		treeItems: tabs.map((t, i) => treeItem(t.id, sidebarSpaceId, i)),
	};
}

// ---------------------------------------------------------------------------

test("optimisticallyActivateTab moves activeTabId immediately", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t1");

	optimisticallyActivateTab("t2");
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");
});

test("optimisticallyActivateTab reuses the view object (===)", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	const viewBefore = getSpaceSidebar(sidebarSpaceId).view;
	optimisticallyActivateTab("t2");
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).view, viewBefore, "view reference must be identical (reuseView)");
});

test("optimisticallyActivateTab is reconciled (not duplicated) by an authoritative patch", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	// Optimistic write
	optimisticallyActivateTab("t2");
	flushSync();
	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");

	// Authoritative patch confirms the same activation (no upserts/removals)
	receive?.({
		event: "browserStatePatch",
		operations: [{ kind: "sidebarChanged", spaceId: sidebarSpaceId, activeTabId: "t2", treeItems: null }],
	});
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");
	assert.equal(getSpaceSidebar(sidebarSpaceId).tabs.length, 2, "no duplicate tabs after reconciliation");
});

test("optimisticallyActivateTab is corrected by an authoritative patch with a different activeTabId", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	mock.timers.enable({ apis: ["setTimeout"] });
	try {
		optimisticallyActivateTab("t2");
		flushSync();
		assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");

		// Host says t1 is still active (e.g. Swift rejected the switch): held briefly, then applied.
		receive?.({
			event: "browserStatePatch",
			operations: [{ kind: "sidebarChanged", spaceId: sidebarSpaceId, activeTabId: "t1", treeItems: null }],
		});
		flushSync();
		assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");

		mock.timers.tick(500);
		flushSync();
		assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t1");
	} finally {
		mock.timers.reset();
	}
});

test("a sidebarChanged sent before the click does not bounce an optimistic activation", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	mock.timers.enable({ apis: ["setTimeout"] });
	try {
		optimisticallyActivateTab("t2");
		flushSync();
		const before = getSpaceSidebar(sidebarSpaceId);

		// In flight when the click happened: a title change that still names t1 as active.
		receive?.({
			event: "browserStatePatch",
			operations: [{
				kind: "sidebarChanged",
				spaceId: sidebarSpaceId,
				activeTabId: "t1",
				upsertTabs: [tab("t1", sidebarSpaceId, { title: "Renamed" })],
				treeItems: null,
			}],
		});
		flushSync();
		assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");
		assert.equal(getSpaceSidebar(sidebarSpaceId).view.tabsById.get("t1")?.title, "Renamed");
		assert.notEqual(getSpaceSidebar(sidebarSpaceId), before);

		receive?.({
			event: "browserStatePatch",
			operations: [{ kind: "sidebarChanged", spaceId: sidebarSpaceId, activeTabId: "t2", treeItems: null }],
		});
		mock.timers.tick(500);
		flushSync();
		assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2", "the confirmation ends the hold");
	} finally {
		mock.timers.reset();
	}
});

test("a full state confirming an optimistic activation ends the hold", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar, receive } = await makeSidebarEnv();
	const tabs = [tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)];

	applySidebarTabInitialState(sidebarInitialState(tabs, "t1"));
	flushSync();

	mock.timers.enable({ apis: ["setTimeout"] });
	try {
		optimisticallyActivateTab("t2");
		receive?.({
			event: "browserStatePatch",
			operations: [{ kind: "sidebarChanged", spaceId: sidebarSpaceId, activeTabId: "t1", treeItems: null }],
		});
		receive?.({
			event: "browserStateChanged",
			changedSpaceId: sidebarSpaceId,
			states: [{ spaceId: sidebarSpaceId, activeTabId: "t2", tabs, folders: [], treeItems: [] }],
		});
		mock.timers.tick(500);
		flushSync();
		assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2", "the stale t1 of the earlier patch must not win");
	} finally {
		mock.timers.reset();
	}
});

test("optimisticallyActivateTab refuses for closed tab", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId, { isClosed: true })],
		"t1",
	));
	flushSync();

	optimisticallyActivateTab("t2");
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t1", "closed tab must not be optimistically activated");
});

test("optimisticallyActivateTab refuses for unknown tab", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	optimisticallyActivateTab("ghost-tab");
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t1", "unknown tab must not be optimistically activated");
});

test("activeTabId-only sidebarChanged patch reuses the view object", async () => {
	const { applySidebarTabInitialState, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	const viewBefore = getSpaceSidebar(sidebarSpaceId).view;

	// Activation-only patch: no upserts, no removals, no treeItems
	receive?.({
		event: "browserStatePatch",
		operations: [{ kind: "sidebarChanged", spaceId: sidebarSpaceId, activeTabId: "t2", treeItems: null }],
	});
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");
	assert.equal(getSpaceSidebar(sidebarSpaceId).view, viewBefore, "view reference must be identical for activeTabId-only patch");
});

test("sidebarChanged patch with upserts recomputes the view (new object)", async () => {
	const { applySidebarTabInitialState, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	const viewBefore = getSpaceSidebar(sidebarSpaceId).view;

	receive?.({
		event: "browserStatePatch",
		operations: [{
			kind: "sidebarChanged",
			spaceId: sidebarSpaceId,
			activeTabId: "t1",
			upsertTabs: [tab("t2", sidebarSpaceId)],
			treeItems: [treeItem("t1", sidebarSpaceId, 0), treeItem("t2", sidebarSpaceId, 1)],
		}],
	});
	flushSync();

	assert.notEqual(getSpaceSidebar(sidebarSpaceId).view, viewBefore, "structural patch must produce a new view object");
});

test("tabUpdated keeps an optimistic activation its buffered activeTabId predates", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId, { isLoading: true, progress: 0.1 }), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	optimisticallyActivateTab("t2");
	flushSync();

	// Buffered on the host before the click reached it: still names t1 as active.
	receive?.({
		event: "browserStatePatch",
		operations: [{
			kind: "tabUpdated",
			spaceId: sidebarSpaceId,
			activeTabId: "t1",
			tab: { id: "t1", spaceId: sidebarSpaceId, progress: 0.5 },
		}],
	});
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId).activeTabId, "t2");
	assert.equal(getSpaceSidebar(sidebarSpaceId).view.tabsById.get("t1")?.progress, 0.5);
});

test("tabUpdated that changes nothing keeps the space record", async () => {
	const { applySidebarTabInitialState, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState([tab("t1", sidebarSpaceId)], "t1"));
	flushSync();

	const before = getSpaceSidebar(sidebarSpaceId);
	receive?.({
		event: "browserStatePatch",
		operations: [{
			kind: "tabUpdated",
			spaceId: sidebarSpaceId,
			activeTabId: "t1",
			tab: { id: "t1", spaceId: sidebarSpaceId, isLoading: false, progress: 1 },
		}],
	});
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId), before);
});

test("confirming an optimistic activation keeps the space record", async () => {
	const { applySidebarTabInitialState, optimisticallyActivateTab, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	optimisticallyActivateTab("t2");
	flushSync();
	const before = getSpaceSidebar(sidebarSpaceId);

	receive?.({
		event: "browserStatePatch",
		operations: [{ kind: "sidebarChanged", spaceId: sidebarSpaceId, activeTabId: "t2", treeItems: null }],
	});
	flushSync();

	assert.equal(getSpaceSidebar(sidebarSpaceId), before);
});

test("full state keeps the snapshot object of a tab that did not change", async () => {
	const { applySidebarTabInitialState, getSpaceSidebar, receive } = await makeSidebarEnv();

	applySidebarTabInitialState(sidebarInitialState(
		[tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId)],
		"t1",
	));
	flushSync();

	const t1Before = getSpaceSidebar(sidebarSpaceId).view.tabsById.get("t1");
	const t2Before = getSpaceSidebar(sidebarSpaceId).view.tabsById.get("t2");
	receive?.({
		event: "browserStateChanged",
		changedSpaceId: sidebarSpaceId,
		activeTabId: "t1",
		states: [{
			spaceId: sidebarSpaceId,
			activeTabId: "t1",
			tabs: [tab("t1", sidebarSpaceId), tab("t2", sidebarSpaceId, { title: "Renamed" })],
			folders: [],
			treeItems: [treeItem("t1", sidebarSpaceId, 0), treeItem("t2", sidebarSpaceId, 1)],
		}],
	});
	flushSync();

	const tabsById = getSpaceSidebar(sidebarSpaceId).view.tabsById;
	assert.equal(tabsById.get("t1"), t1Before);
	assert.notEqual(tabsById.get("t2"), t2Before);
	assert.equal(tabsById.get("t2")?.title, "Renamed");
});
