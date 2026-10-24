import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("folder root projections react to folder-only pinned-state bridge updates", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { getRootItems, getFolders } = await loadStore("/src/stores/folders.svelte.ts");
	const { applySidebarFolderInitialState, applySidebarTabInitialState, initSidebarStore } = await loadStore(
		"/src/stores/sidebar.svelte.ts",
	);
	const { applySpaceInitialState } = await loadStore(
		"/src/stores/spaces.svelte.ts",
	);
	const spaceId = "folder-reactive-space";
	const baseState = {
		tabs: [],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: spaceId,
				name: "Reactive",
				icon: "square",
				color: "#000000",
				profileId: "p1",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		activeSpaceId: spaceId,
		folders: [
			{
				id: "reactive-folder",
				spaceId,
				name: "Reactive Folder",
				color: "#444444",
				sortOrder: 0,
				isCollapsed: false,
				isPinned: false,
			},
		],
		treeItems: [
			{
				id: `${spaceId}-reactive-folder-root`,
				spaceId,
				kind: "folder" as const,
				itemId: "reactive-folder",
				parentFolderId: null,
				section: "unpinned" as const,
				sortOrder: 0,
			},
		],
	};

	applySpaceInitialState(baseState);
	applySidebarTabInitialState(baseState);
	applySidebarFolderInitialState(baseState);
	initSidebarStore();

	assert.deepEqual(getRootItems(spaceId, true), []);
	assert.equal(getFolders(spaceId)[0]?.name, "Reactive Folder");
	assert.deepEqual(getRootItems(spaceId, false), [
		{ kind: "folder", id: "reactive-folder" },
	]);

	(
		globalThis as {
			window: {
				__lilo?: {
					receive(msg: Record<string, unknown>): void;
				};
			};
		}
	).window.__lilo?.receive({
		event: "browserStateChanged",
		changedSpaceId: spaceId,
		activeTabId: "",
		states: [
			{
				spaceId,
				activeTabId: "",
				tabs: [],
				folders: [
					{
						id: "reactive-folder",
						spaceId,
						name: "Renamed Folder",
						color: "#444444",
						sortOrder: 0,
						isCollapsed: true,
						isPinned: true,
					},
				],
				treeItems: [
					{
						id: `${spaceId}-reactive-folder-root`,
						spaceId,
						kind: "folder",
						itemId: "reactive-folder",
						parentFolderId: null,
						section: "pinned",
						sortOrder: 0,
					},
				],
			},
		],
	});
	flushSync();

	assert.equal(getFolders(spaceId)[0]?.name, "Renamed Folder");
	assert.equal(getFolders(spaceId)[0]?.isCollapsed, true);
	assert.deepEqual(getRootItems(spaceId, true), [
		{ kind: "folder", id: "reactive-folder" },
	]);
	assert.deepEqual(getRootItems(spaceId, false), []);
});
