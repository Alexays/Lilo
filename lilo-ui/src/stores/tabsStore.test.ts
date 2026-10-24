import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { tab, treeItem } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("pending and preview move-space hide the tab from its source space until the move lands", async (t) => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const {
		clearPreviewTabMoveToSpace,
		queuePendingTabDrop,
		setPreviewTabMoveToSpace,
	} = await loadStore("/src/stores/dropConfirmation.svelte.ts");
	const { getTabs } = await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");

	applySidebarTabInitialState({
		activeSpaceId: "source-space",
		activeTabId: "moving-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "source-space",
				name: "Source",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: "target-space",
				name: "Target",
				icon: "T",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		tabs: [
			tab("moving-tab", "source-space"),
			tab("stable-tab", "source-space"),
		],
		treeItems: [
			treeItem("moving-tab", "source-space", 0),
			treeItem("stable-tab", "source-space", 1),
		],
	} satisfies BridgeInitialStatePayload);

	setPreviewTabMoveToSpace("moving-tab", "target-space");
	flushSync();

	assert.deepEqual(
		getTabs("source-space").map((item: { id: string }) => item.id),
		["stable-tab"],
	);
	assert.deepEqual(getTabs("target-space").map((item: { id: string }) => item.id), []);

	clearPreviewTabMoveToSpace("moving-tab");
	flushSync();
	assert.deepEqual(
		getTabs("source-space").map((item: { id: string }) => item.id),
		["moving-tab", "stable-tab"],
	);

	t.mock.timers.enable({ apis: ["setTimeout"] });
	queuePendingTabDrop({
		tabId: "moving-tab",
		kind: "move-space",
		targetSpaceId: "target-space",
	});
	flushSync();

	assert.deepEqual(
		getTabs("source-space").map((item: { id: string }) => item.id),
		["stable-tab"],
	);
	assert.deepEqual(getTabs("target-space").map((item: { id: string }) => item.id), []);

	t.mock.timers.tick(1500);
	flushSync();
	assert.deepEqual(
		getTabs("source-space").map((item: { id: string }) => item.id),
		["moving-tab", "stable-tab"],
	);
});

test("bookmarked tabs follow sidebar treeItems order", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getBookmarkedTabs } = await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarFolderInitialState, applySidebarTabInitialState } = await loadStore(
		"/src/stores/sidebar.svelte.ts",
	);

	const initial = {
		activeSpaceId: "space",
		activeTabId: "middle",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [
			tab("last-by-tree", "space", { isBookmarked: true }),
			tab("first-by-tree", "space", { isBookmarked: true }),
			tab("middle", "space", { isBookmarked: true }),
		],
		treeItems: [
			treeItem("first-by-tree", "space", 0, "bookmarked"),
			treeItem("middle", "space", 1, "bookmarked"),
			treeItem("last-by-tree", "space", 2, "bookmarked"),
		],
	} satisfies BridgeInitialStatePayload;
	applySidebarTabInitialState(initial);
	applySidebarFolderInitialState(initial);
	flushSync();

	assert.deepEqual(
		getBookmarkedTabs("space").map((item: { id: string }) => item.id),
		["first-by-tree", "middle", "last-by-tree"],
	);
});

test("browserStatePatch tabUpdated patches one tab without replacing the whole space state", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getActiveTabId, getTabs, initTabStore } =
		await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	applySidebarTabInitialState({
		activeSpaceId: "space",
		activeTabId: "stable-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [
			tab("stable-tab", "space"),
			tab("loading-tab", "space", { progress: 0.1, isLoading: true }),
		],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);

	(
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
		).window.__lilo?.receive({
			event: "browserStatePatch",
			changedSpaceId: "space",
			activeTabId: "stable-tab",
			operations: [
				{
					kind: "tabUpdated",
					spaceId: "space",
					activeTabId: "stable-tab",
					tab: tab("loading-tab", "space", {
						title: "Still loading",
						progress: 0.75,
						isLoading: true,
					}),
				},
			],
		});
	flushSync();

	assert.equal(getActiveTabId("space"), "stable-tab");
	assert.deepEqual(
		getTabs("space").map((item: { id: string; title: string; progress: number }) => [
			item.id,
			item.title,
			item.progress,
		]),
		[
			["stable-tab", "stable-tab", 1],
			["loading-tab", "Still loading", 0.75],
		],
	);
});

test("browserStatePatch applies every tabUpdated of one patch on top of the previous ones", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getTabs, getTabsById, initTabStore } =
		await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	applySidebarTabInitialState({
		activeSpaceId: "space",
		activeTabId: "stable-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [tab("stable-tab", "space"), tab("loading-tab", "space", { progress: 0.1 })],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);

	(
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
	).window.__lilo?.receive({
		event: "browserStatePatch",
		changedSpaceId: "space",
		activeTabId: "stable-tab",
		operations: [
			{ kind: "tabUpdated", spaceId: "space", tab: { id: "loading-tab", title: "Loaded" } },
			{ kind: "tabUpdated", spaceId: "space", tab: { id: "loading-tab", progress: 0.9 } },
			{ kind: "tabUpdated", spaceId: "space", tab: { id: "stable-tab", title: "Renamed" } },
		],
	});
	flushSync();

	const expected = [
		["stable-tab", "Renamed", 1],
		["loading-tab", "Loaded", 0.9],
	];
	const row = (item: { id: string; title: string; progress: number }) => [
		item.id,
		item.title,
		item.progress,
	];
	assert.deepEqual(getTabs("space").map(row), expected);
	assert.deepEqual([...getTabsById("space").values()].map(row), expected);
});

test("browserStatePatch tabUpdated without a favicon preserves the existing favicon", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getTabs, initTabStore } =
		await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	applySidebarTabInitialState({
		activeSpaceId: "space",
		activeTabId: "fav-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [
			tab("fav-tab", "space", {
				faviconDataURL: "data:image/png;base64,AAAA",
				progress: 0.1,
				isLoading: true,
			}),
		],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);

	// A runtime patch omits the favicon entirely (Tab.runtimePatchData on the Swift side).
	(
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
	).window.__lilo?.receive({
		event: "browserStatePatch",
		changedSpaceId: "space",
		activeTabId: "fav-tab",
		operations: [
			{
				kind: "tabUpdated",
				spaceId: "space",
				activeTabId: "fav-tab",
				tab: { id: "fav-tab", spaceId: "space", progress: 0.75, isLoading: false },
			},
		],
	});
	flushSync();

	const updated = getTabs("space").find(
		(item: { id: string }) => item.id === "fav-tab",
	) as { faviconDataURL?: string; progress: number; isLoading: boolean };
	assert.equal(updated.faviconDataURL, "data:image/png;base64,AAAA");
	assert.equal(updated.progress, 0.75);
	assert.equal(updated.isLoading, false);
});

test("browserStatePatch sidebarChanged moves the active id and reopens via upsert", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getActiveTabId, getTabs, initTabStore } =
		await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	applySidebarTabInitialState({
		activeSpaceId: "space",
		activeTabId: "first-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [
			tab("first-tab", "space"),
			tab("second-tab", "space", { isClosed: true }),
		],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);

	(
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
		).window.__lilo?.receive({
			event: "browserStatePatch",
			changedSpaceId: "space",
			activeTabId: "second-tab",
			operations: [
				{
					kind: "sidebarChanged",
					spaceId: "space",
					activeTabId: "second-tab",
					upsertTabs: [
						tab("second-tab", "space", {
							title: "Second reopened",
							isClosed: false,
						}),
					],
				},
			],
		});
	flushSync();

	assert.equal(getActiveTabId("space"), "second-tab");
	assert.deepEqual(
		getTabs("space").map((item: { id: string; title: string; isClosed: boolean }) => [
			item.id,
			item.title,
			item.isClosed,
		]),
		[
			["first-tab", "first-tab", false],
			["second-tab", "Second reopened", false],
		],
	);
});

test("browserStatePatch sidebarChanged inserts a created tab and moves the active id", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getActiveTabId, getTabs, initTabStore } =
		await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	applySidebarTabInitialState({
		activeSpaceId: "space",
		activeTabId: "existing-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [tab("existing-tab", "space")],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);

	(
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
	).window.__lilo?.receive({
		event: "browserStatePatch",
		changedSpaceId: "space",
		activeTabId: "new-tab",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId: "space",
				activeTabId: "new-tab",
				upsertTabs: [tab("new-tab", "space", { url: "" })],
				treeItems: [treeItem("existing-tab", "space", 0), treeItem("new-tab", "space", 1)],
			},
		],
	});
	flushSync();

	assert.deepEqual(
		getTabs("space").map((item: { id: string }) => item.id),
		["existing-tab", "new-tab"],
	);
	assert.equal(getActiveTabId("space"), "new-tab");
});

test("browserStatePatch sidebarChanged removes a pruned tab and keeps a pinned survivor", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getActiveTabId, getTabs, initTabStore } =
		await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	initTabStore();

	applySidebarTabInitialState({
		activeSpaceId: "space",
		activeTabId: "doomed-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [
			tab("doomed-tab", "space"),
			tab("other-tab", "space"),
			tab("pinned-tab", "space", { isPinned: true }),
		],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);

	const receive = (
		globalThis as {
			window: {
				__lilo?: { receive(msg: Record<string, unknown>): void };
			};
		}
	).window.__lilo?.receive;

	// Pruned close: no surviving snapshot, so the tab disappears and active moves on.
	receive?.({
		event: "browserStatePatch",
		changedSpaceId: "space",
		activeTabId: "other-tab",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId: "space",
				activeTabId: "other-tab",
				removedTabIds: ["doomed-tab"],
				treeItems: [
					treeItem("pinned-tab", "space", 0, "pinned"),
					treeItem("other-tab", "space", 0),
				],
			},
		],
	});
	flushSync();

	assert.deepEqual(
		getTabs("space").map((item: { id: string }) => item.id),
		["other-tab", "pinned-tab"],
	);
	assert.equal(getActiveTabId("space"), "other-tab");

	// Pinned close: the snapshot survives with isClosed = true instead of vanishing.
	receive?.({
		event: "browserStatePatch",
		changedSpaceId: "space",
		activeTabId: "other-tab",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId: "space",
				activeTabId: "other-tab",
				upsertTabs: [tab("pinned-tab", "space", { isPinned: true, isClosed: true })],
				treeItems: [
					treeItem("pinned-tab", "space", 0, "pinned"),
					treeItem("other-tab", "space", 0),
				],
			},
		],
	});
	flushSync();

	assert.deepEqual(
		getTabs("space").map((item: { id: string; isClosed: boolean }) => [item.id, item.isClosed]),
		[
			["other-tab", false],
			["pinned-tab", true],
		],
	);
});
