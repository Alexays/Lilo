import test from "node:test";
import assert from "node:assert/strict";
import type { FolderState, TabState } from "./folders.svelte";
import { treeItem } from "./testFixtures";

(
	globalThis as unknown as {
		window?: Record<string, unknown>;
		$state?: <T>(value: T) => T;
	}
).window ??= {
	__liloBootstrapEvents: [],
};
type StateRune = (<T>(value: T) => T) & { raw: <T>(value: T) => T };
(globalThis as { $state?: StateRune }).$state ??= Object.assign(
	<T>(value: T) => value,
	{ raw: <T>(value: T) => value },
);
// The command bar store reads the pager's paged Spaces, a module-level $derived.
type DerivedRune = (<T>(value: T) => T) & { by: <T>(fn: () => T) => T };
(globalThis as { $derived?: DerivedRune }).$derived ??= Object.assign(
	<T>(value: T) => value,
	{ by: <T>(fn: () => T) => fn() },
);

const {
	getRootItems,
	getFolders,
	getVisibleFolderChildren,
	countVisibleFolderChildren,
	canNestFolder,
} = await import("./folders.svelte");
const { applySidebarFolderInitialState, applySidebarTabInitialState, initSidebarStore } = await import("./sidebar.svelte");
const { computeSidebarView } = await import("./sidebarView");
const { getTabs: getSpaceTabs } = await import("./tabs.svelte");
const { applySpaceInitialState } = await import("./spaces.svelte");

function tabsByIdFor(spaceId: string): Map<string, TabState> {
	return new Map(getSpaceTabs(spaceId).map((tab) => [tab.id, tab]));
}

type SeedTab = {
	id: string;
	groupId?: string;
	isPinned: boolean;
	isBookmarked: boolean;
	isClosed: boolean;
};

// Seed the folder store through the host's initial-state appliers so getRootItems(spaceId, pinned)
// can project roots.
function seedRoots(
	spaceId: string,
	tabs: SeedTab[],
	folders: Array<{ id: string }>,
	treeItems: ReturnType<typeof treeItem>[],
): void {
	const spaces = [
		{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 },
	];
	const initialState = {
		tabs: tabs.map((tab) => makeTab({ ...tab, spaceId })),
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		activeSpaceId: spaceId,
	};
	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState({
		...initialState,
		folders: folders.map((folder) => makeFolder({ ...folder, spaceId } as Partial<FolderState> & Pick<FolderState, "id">)),
		treeItems,
	});
}

function makeTab(tab: Partial<TabState> & Pick<TabState, "id">): TabState {
	return tab as TabState;
}

function makeFolder(folder: Partial<FolderState> & Pick<FolderState, "id">): FolderState {
	return folder as FolderState;
}


test("getRootItems: orders roots from treeItems", () => {
	const spaceId = "resolve-roots-order";
	seedRoots(
		spaceId,
		[
			{ id: "t1", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "t2", isPinned: false, isBookmarked: false, isClosed: false },
		],
		[{ id: "f1" }],
		[
			treeItem("t1", spaceId, 0),
			treeItem("f1", spaceId, 1, "unpinned", "folder"),
			treeItem("t2", spaceId, 2),
		],
	);
	const root = getRootItems(spaceId, false);

	assert.deepEqual(
		root.map((item) => item.id),
		["t1", "f1", "t2"],
	);
	assert.deepEqual(
		root.map((item) => item.kind),
		["tab", "folder", "tab"],
	);
});

test("getRootItems: skips child tabs from root treeItems", () => {
	const spaceId = "resolve-roots-skip-children";
	seedRoots(
		spaceId,
		[
			{ id: "t1", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "t2", groupId: "f1", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "t3", isPinned: false, isBookmarked: false, isClosed: false },
		],
		[{ id: "f1" }],
		[
			treeItem("t1", spaceId, 0),
			treeItem("f1", spaceId, 1, "unpinned", "folder"),
			treeItem("t2", spaceId, 0, "unpinned", "tab", "f1"),
			treeItem("t3", spaceId, 2),
		],
	);
	const root = getRootItems(spaceId, false);

	assert.deepEqual(
		root.map((item) => item.id),
		["t1", "f1", "t3"],
	);
});

test("getRootItems: keeps treeItems order", () => {
	const spaceId = "resolve-roots-keep-order";
	seedRoots(
		spaceId,
		[
			{ id: "t1", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "t2", isPinned: false, isBookmarked: false, isClosed: false },
		],
		[],
		[
			treeItem("t2", spaceId, 0),
			treeItem("t1", spaceId, 1),
		],
	);
	const root = getRootItems(spaceId, false);

	assert.deepEqual(
		root.map((item) => item.id),
		["t2", "t1"],
	);
});

test("getRootItems: same sortOrder follows tree item sequence", () => {
	const spaceId = "resolve-roots-tied";
	seedRoots(
		spaceId,
		[{ id: "tab-1", isPinned: false, isBookmarked: false, isClosed: false }],
		[{ id: "folder-1" }],
		[
			treeItem("folder-1", spaceId, 0, "unpinned", "folder"),
			treeItem("tab-1", spaceId, 0),
		],
	);

	assert.deepEqual(getRootItems(spaceId, false), [
		{ kind: "folder", id: "folder-1" },
		{ kind: "tab", id: "tab-1" },
	]);
});

test("getRootItems: ignores roots missing from treeItems", () => {
	const spaceId = "resolve-roots-missing";
	seedRoots(
		spaceId,
		[
			{ id: "tab-1", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "tab-new", isPinned: false, isBookmarked: false, isClosed: false },
		],
		[],
		[treeItem("tab-1", spaceId, 0)],
	);

	assert.deepEqual(getRootItems(spaceId, false), [{ kind: "tab", id: "tab-1" }]);
});

test("the sidebar view precomputes roots and folder children by section", () => {
	const index = computeSidebarView([], [], [
		treeItem("folder-1", "space", 0, "unpinned", "folder"),
		treeItem("child-2", "space", 1, "unpinned", "tab", "folder-1"),
		treeItem("child-1", "space", 0, "unpinned", "tab", "folder-1"),
		treeItem("pinned-tab", "space", 0, "pinned"),
	]).treeIndex;

	assert.deepEqual(
		index.rootItemsBySection.unpinned.map((item) => item.itemId),
		["folder-1"],
	);
	assert.deepEqual(
		index.rootItemsBySection.pinned.map((item) => item.itemId),
		["pinned-tab"],
	);
	assert.deepEqual(
		index.childrenByFolderId.get("folder-1")?.map((item) => item.itemId),
		["child-1", "child-2"],
	);
});

function seedRootProjectionState(spaceId: string): void {
	const initialState = {
		tabs: [
			{
				id: "pinned-root",
				spaceId,
				isPinned: true,
				isBookmarked: false,
				isClosed: false,
			},
			{
				id: "pinned-in-folder",
				spaceId,
				groupId: "pinned-folder",
				isPinned: true,
				isBookmarked: false,
				isClosed: false,
			},
			{
				id: "pinned-bookmark",
				spaceId,
				isPinned: true,
				isBookmarked: true,
				isClosed: false,
			},
			{
				id: "pinned-closed",
				spaceId,
				isPinned: true,
				isBookmarked: false,
				isClosed: true,
			},
			{
				id: "unpinned-root",
				spaceId,
				isPinned: false,
				isBookmarked: false,
				isClosed: false,
			},
			{
				id: "unpinned-bookmark",
				spaceId,
				isPinned: false,
				isBookmarked: true,
				isClosed: false,
			},
			{
				id: "unpinned-closed",
				spaceId,
				isPinned: false,
				isBookmarked: false,
				isClosed: true,
			},
		] as Parameters<typeof applySidebarTabInitialState>[0]["tabs"],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: spaceId,
				name: "Space",
				icon: "square",
				color: "#000000",
				profileId: "profile-1",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		activeSpaceId: spaceId,
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);

	applySidebarFolderInitialState({
		...initialState,
		folders: [
			makeFolder({
				id: "pinned-folder",
				spaceId,
				name: "Pinned",
				color: "#000000",
				isCollapsed: false,
			}),
			makeFolder({
				id: "unpinned-folder",
				spaceId,
				name: "Unpinned",
				color: "#ffffff",
				isCollapsed: false,
			}),
		],
		treeItems: [
			treeItem("pinned-folder", spaceId, 0, "pinned", "folder"),
			treeItem("pinned-in-folder", spaceId, 0, "pinned", "tab", "pinned-folder"),
			treeItem("pinned-root", spaceId, 1, "pinned"),
			treeItem("pinned-closed", spaceId, 2, "pinned"),
			treeItem("unpinned-root", spaceId, 0),
			treeItem("unpinned-folder", spaceId, 1, "unpinned", "folder"),
		],
	});
	}

test("getRootItems with pinned=true returns only pinned roots", () => {
	const spaceId = "root-pinned-space";
	seedRootProjectionState(spaceId);

	assert.deepEqual(getRootItems(spaceId, true), [
		{ kind: "folder", id: "pinned-folder" },
		{ kind: "tab", id: "pinned-root" },
		{ kind: "tab", id: "pinned-closed" },
	]);
});

test("getRootItems with pinned=false returns only unpinned roots", () => {
	const spaceId = "root-unpinned-space";
	seedRootProjectionState(spaceId);

	assert.deepEqual(getRootItems(spaceId, false), [
		{ kind: "tab", id: "unpinned-root" },
		{ kind: "folder", id: "unpinned-folder" },
	]);
});

test("getRootItems without spaceId uses the active space for folders and tabs", () => {
	const spaceId = "root-active-space";
	seedRootProjectionState(spaceId);

	assert.deepEqual(getRootItems(undefined, true), [
		{ kind: "folder", id: "pinned-folder" },
		{ kind: "tab", id: "pinned-root" },
		{ kind: "tab", id: "pinned-closed" },
	]);
});

// Sectioned rendering contract tests

test("sectioned rendering: getRootItems default (no pinned arg) equals explicit pinned=false", () => {
	const spaceId = "section-default-space";
	seedRootProjectionState(spaceId);

	assert.deepEqual(getRootItems(spaceId), getRootItems(spaceId, false));
});

test("sectioned rendering: getRootItems respects pinned flag", () => {
	const spaceId = "section-pinned-flag-space";
	seedRoots(
		spaceId,
		[
			{ id: "tp1", isPinned: true, isBookmarked: false, isClosed: false },
			{ id: "tu1", isPinned: false, isBookmarked: false, isClosed: false },
		],
		[{ id: "fp1" }, { id: "fu1" }],
		[
			treeItem("tp1", spaceId, 0, "pinned"),
			treeItem("fp1", spaceId, 1, "pinned", "folder"),
			treeItem("tu1", spaceId, 0),
			treeItem("fu1", spaceId, 1, "unpinned", "folder"),
		],
	);

	const pinned = getRootItems(spaceId, true);
	assert.deepEqual(pinned, [
		{ kind: "tab", id: "tp1" },
		{ kind: "folder", id: "fp1" },
	]);

	const unpinned = getRootItems(spaceId, false);
	assert.deepEqual(unpinned, [
		{ kind: "tab", id: "tu1" },
		{ kind: "folder", id: "fu1" },
	]);
});

test("sectioned rendering: tied pinned roots keep flat-index tab rows ahead of folders", () => {
	const spaceId = "section-tied-pinned-space";
	seedRoots(
		spaceId,
		[{ id: "pinned-tab", isPinned: true, isBookmarked: false, isClosed: false }],
		[{ id: "pinned-folder" }],
		[
			treeItem("pinned-tab", spaceId, 0, "pinned"),
			treeItem("pinned-folder", spaceId, 1, "pinned", "folder"),
		],
	);
	const pinned = getRootItems(spaceId, true);

	assert.deepEqual(pinned, [
		{ kind: "tab", id: "pinned-tab" },
		{ kind: "folder", id: "pinned-folder" },
	]);
});

// getVisibleFolderChildren

function seedVisibleFolderTabsState(spaceId: string): void {
	const initialState = {
		tabs: [
			makeTab({ id: "vft-normal", spaceId, groupId: "f1", isPinned: false, isBookmarked: false, isClosed: false }),
			makeTab({ id: "vft-bookmarked", spaceId, groupId: "f1", isPinned: false, isBookmarked: true, isClosed: false }),
			makeTab({ id: "vft-closed", spaceId, groupId: "f1", isPinned: false, isBookmarked: false, isClosed: true }),
			makeTab({ id: "vft-other-folder", spaceId, groupId: "f2", isPinned: false, isBookmarked: false, isClosed: false }),
			makeTab({ id: "vft-root", spaceId, isPinned: false, isBookmarked: false, isClosed: false }),
		],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: spaceId,
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState({
		...initialState,
		folders: [],
		treeItems: [
			treeItem("vft-normal", spaceId, 0, "unpinned", "tab", "f1"),
			treeItem("vft-bookmarked", spaceId, 1, "unpinned", "tab", "f1"),
			treeItem("vft-closed", spaceId, 2, "unpinned", "tab", "f1"),
			treeItem("vft-other-folder", spaceId, 0, "unpinned", "tab", "f2"),
			treeItem("vft-root", spaceId, 0),
		],
	});
}

test("getVisibleFolderChildren: returns only the folder's own active (non-bookmarked, non-closed) tabs", () => {
	const spaceId = "vft-space-1";
	seedVisibleFolderTabsState(spaceId);

	const visible = getVisibleFolderChildren("f1", spaceId);
	assert.deepEqual(visible.map((t) => t.id), ["vft-normal"]);
});

test("getVisibleFolderChildren length: pinned counts only visible pinned children", () => {
	const spaceId = "visible-folder-child-count-space";
	const initialState = {
		tabs: [
			makeTab({ id: "pinned-open", spaceId, groupId: "f1", isPinned: true, isBookmarked: false, isClosed: false }),
			makeTab({ id: "pinned-closed", spaceId, groupId: "f1", isPinned: true, isBookmarked: false, isClosed: true }),
			makeTab({ id: "pinned-bookmarked", spaceId, groupId: "f1", isPinned: true, isBookmarked: true, isClosed: false }),
			makeTab({ id: "unpinned-open", spaceId, groupId: "f1", isPinned: false, isBookmarked: false, isClosed: false }),
		],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: spaceId,
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState({
		...initialState,
		folders: [],
		treeItems: [
			treeItem("pinned-open", spaceId, 0, "pinned", "tab", "f1"),
			treeItem("pinned-closed", spaceId, 1, "pinned", "tab", "f1"),
			treeItem("pinned-bookmarked", spaceId, 2, "pinned", "tab", "f1"),
			treeItem("unpinned-open", spaceId, 0, "unpinned", "tab", "f1"),
		],
	});

	assert.equal(getVisibleFolderChildren("f1", spaceId, true).length, 2);
	assert.equal(getVisibleFolderChildren("f1", spaceId, false).length, 1);
});

test("countVisibleFolderChildren: matches getVisibleFolderChildren length", () => {
	const spaceId = "count-visible-folder-tabs-space";
	seedRoots(
		spaceId,
		[
			{ id: "p-open", groupId: "f1", isPinned: true, isBookmarked: false, isClosed: false },
			{ id: "p-closed", groupId: "f1", isPinned: true, isBookmarked: false, isClosed: true },
			{ id: "p-bookmarked", groupId: "f1", isPinned: true, isBookmarked: true, isClosed: false },
			{ id: "u-open", groupId: "f1", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "u-closed", groupId: "f1", isPinned: false, isBookmarked: false, isClosed: true },
			{ id: "u-bookmarked", groupId: "f1", isPinned: false, isBookmarked: true, isClosed: false },
			{ id: "u-closed-pinned", groupId: "f1", isPinned: true, isBookmarked: false, isClosed: true },
			{ id: "f2-open", groupId: "f2", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "f2-closed", groupId: "f2", isPinned: true, isBookmarked: false, isClosed: true },
			{ id: "root-open", isPinned: false, isBookmarked: false, isClosed: false },
		],
		[{ id: "f1" }, { id: "f2" }, { id: "f-empty" }],
		[
			treeItem("f1", spaceId, 0, "unpinned", "folder"),
			treeItem("f2", spaceId, 1, "pinned", "folder"),
			treeItem("f-empty", spaceId, 2, "unpinned", "folder"),
			treeItem("root-open", spaceId, 3),
			treeItem("p-open", spaceId, 0, "pinned", "tab", "f1"),
			treeItem("p-closed", spaceId, 1, "pinned", "tab", "f1"),
			treeItem("p-bookmarked", spaceId, 2, "pinned", "tab", "f1"),
			treeItem("u-open", spaceId, 0, "unpinned", "tab", "f1"),
			treeItem("u-closed", spaceId, 1, "unpinned", "tab", "f1"),
			treeItem("u-bookmarked", spaceId, 2, "bookmarked", "tab", "f1"),
			treeItem("u-closed-pinned", spaceId, 3, "unpinned", "tab", "f1"),
			treeItem("f2-open", spaceId, 0, "unpinned", "tab", "f2"),
			treeItem("f2-closed", spaceId, 1, "pinned", "tab", "f2"),
		],
	);
	const tabsById = tabsByIdFor(spaceId);

	for (const folderId of ["f1", "f2", "f-empty", "missing"]) {
		for (const pinned of [true, false, undefined]) {
			assert.equal(
				countVisibleFolderChildren(folderId, spaceId, pinned, tabsById),
				getVisibleFolderChildren(folderId, spaceId, pinned, tabsById).length,
				`${folderId} pinned=${pinned}`,
			);
		}
	}
	assert.equal(countVisibleFolderChildren("f1", spaceId, true, tabsById), 2);
});

test("getVisibleFolderChildren: pinned section keeps closed pinned folder children visible", () => {
	const spaceId = "visible-folder-pinned-children-space";
	const initialState = {
		tabs: [
			makeTab({ id: "pinned-child", spaceId, groupId: "f1", isPinned: true, isBookmarked: false, isClosed: false }),
			makeTab({ id: "pinned-closed-child", spaceId, groupId: "f1", isPinned: true, isBookmarked: false, isClosed: true }),
			makeTab({ id: "unpinned-child", spaceId, groupId: "f1", isPinned: false, isBookmarked: false, isClosed: false }),
			makeTab({ id: "pinned-bookmarked-child", spaceId, groupId: "f1", isPinned: true, isBookmarked: true, isClosed: false }),
		],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: spaceId,
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState({
		...initialState,
		folders: [],
		treeItems: [
			treeItem("pinned-child", spaceId, 0, "pinned", "tab", "f1"),
			treeItem("pinned-closed-child", spaceId, 1, "pinned", "tab", "f1"),
			treeItem("unpinned-child", spaceId, 0, "unpinned", "tab", "f1"),
			treeItem("pinned-bookmarked-child", spaceId, 2, "pinned", "tab", "f1"),
		],
	});

	assert.deepEqual(
		getVisibleFolderChildren("f1", spaceId, true).map((tab) => tab.id),
		["pinned-child", "pinned-closed-child"],
	);
});

test("getVisibleFolderChildren: unpinned section only returns unpinned folder children", () => {
	const spaceId = "visible-folder-unpinned-children-space";
	const initialState = {
		tabs: [
			makeTab({ id: "pinned-child", spaceId, groupId: "f1", isPinned: true, isBookmarked: false, isClosed: false }),
			makeTab({ id: "unpinned-child", spaceId, groupId: "f1", isPinned: false, isBookmarked: false, isClosed: false }),
			makeTab({ id: "unpinned-closed-child", spaceId, groupId: "f1", isPinned: false, isBookmarked: false, isClosed: true }),
		],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: spaceId,
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState({
		...initialState,
		folders: [],
		treeItems: [
			treeItem("pinned-child", spaceId, 0, "pinned", "tab", "f1"),
			treeItem("unpinned-child", spaceId, 0, "unpinned", "tab", "f1"),
			treeItem("unpinned-closed-child", spaceId, 1, "unpinned", "tab", "f1"),
		],
	});

	assert.deepEqual(
		getVisibleFolderChildren("f1", spaceId, false).map((tab) => tab.id),
		["unpinned-child"],
	);
});

test("shared tabsById Map yields identical getVisibleFolderChildren output", () => {
	const folderSpaceId = "shared-map-folder-space";
	seedVisibleFolderTabsState(folderSpaceId);
	const folderTabsById = tabsByIdFor(folderSpaceId);
	assert.deepEqual(
		getVisibleFolderChildren("f1", folderSpaceId, false, folderTabsById),
		getVisibleFolderChildren("f1", folderSpaceId, false),
	);
});

// outer > middle > inner, each holding one tab, plus a root folder `loose` holding `loose-sub`.
function seedNestedFolders(spaceId: string): void {
	seedRoots(
		spaceId,
		[
			{ id: "outer-tab", groupId: "outer", isPinned: false, isBookmarked: false, isClosed: false },
			{ id: "inner-tab", groupId: "inner", isPinned: false, isBookmarked: false, isClosed: false },
		],
		[{ id: "outer" }, { id: "middle" }, { id: "inner" }, { id: "loose" }, { id: "loose-sub" }],
		[
			treeItem("outer", spaceId, 0, "unpinned", "folder"),
			treeItem("middle", spaceId, 0, "unpinned", "folder", "outer"),
			treeItem("outer-tab", spaceId, 1, "unpinned", "tab", "outer"),
			treeItem("inner", spaceId, 0, "unpinned", "folder", "middle"),
			treeItem("inner-tab", spaceId, 0, "unpinned", "tab", "inner"),
			treeItem("loose", spaceId, 1, "unpinned", "folder"),
			treeItem("loose-sub", spaceId, 0, "unpinned", "folder", "loose"),
		],
	);
}

test("getVisibleFolderChildren: lists subfolders with the tabs, in order", () => {
	const spaceId = "nested-children-space";
	seedNestedFolders(spaceId);
	const tabsById = tabsByIdFor(spaceId);

	assert.deepEqual(getVisibleFolderChildren("outer", spaceId, false, tabsById), [
		{ kind: "folder", id: "middle" },
		{ kind: "tab", id: "outer-tab" },
	]);
	assert.equal(countVisibleFolderChildren("outer", spaceId, false, tabsById), 2);
	assert.deepEqual(getVisibleFolderChildren("middle", spaceId, false, tabsById), [{ kind: "folder", id: "inner" }]);
	assert.deepEqual(getVisibleFolderChildren("outer", spaceId, true, tabsById), []);
});

test("canNestFolder: refuses a folder into itself, its subtree or past five levels", () => {
	const spaceId = "nested-depth-space";
	seedNestedFolders(spaceId);

	assert.equal(canNestFolder("outer", "outer", spaceId), false);
	assert.equal(canNestFolder("outer", "inner", spaceId), false);
	assert.equal(canNestFolder("middle", "inner", spaceId), false);
	assert.equal(canNestFolder("inner", "outer", spaceId), true);
	// loose is two levels deep: under inner, at depth 3, it reaches the fifth.
	assert.equal(canNestFolder("loose", "inner", spaceId), true);
	assert.equal(canNestFolder("loose-sub", "inner", spaceId), true);
	seedRoots(
		spaceId,
		[],
		[{ id: "d1" }, { id: "d2" }, { id: "d3" }, { id: "d4" }, { id: "d5" }, { id: "solo" }],
		[
			treeItem("d1", spaceId, 0, "unpinned", "folder"),
			treeItem("d2", spaceId, 0, "unpinned", "folder", "d1"),
			treeItem("d3", spaceId, 0, "unpinned", "folder", "d2"),
			treeItem("d4", spaceId, 0, "unpinned", "folder", "d3"),
			treeItem("d5", spaceId, 0, "unpinned", "folder", "d4"),
			treeItem("solo", spaceId, 1, "unpinned", "folder"),
		],
	);
	assert.equal(canNestFolder("solo", "d4", spaceId), true);
	assert.equal(canNestFolder("solo", "d5", spaceId), false);
});

test("folder bridge hydration: initialState and browserStateChanged keep store in sync", () => {
	const spaceId = "folder-bridge-space";
	const baseState = {
		tabs: [] as Parameters<typeof applySidebarTabInitialState>[0]["tabs"],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: spaceId,
		folders: [
			{
				id: "initial-folder",
				spaceId,
				name: "Initial",
				color: "#111111",
				sortOrder: 0,
				isCollapsed: false,
				isPinned: true,
			},
		],
		treeItems: [treeItem("initial-folder", spaceId, 0, "pinned", "folder")],
	};

	applySpaceInitialState(baseState);
	applySidebarTabInitialState(baseState);
	applySidebarFolderInitialState(baseState as Parameters<typeof applySidebarFolderInitialState>[0]);
	assert.deepEqual(getRootItems(spaceId, true), [{ kind: "folder", id: "initial-folder" }]);

	initSidebarStore();
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
		profileId: "p1",
		activeTabId: "",
		states: [
			{
				spaceId,
				activeTabId: "",
				tabs: [],
				folders: [
					{
						id: "ready-folder",
						spaceId,
						name: "Ready",
						color: "#222222",
						sortOrder: 0,
						isCollapsed: false,
						isPinned: false,
					},
				],
				treeItems: [treeItem("ready-folder", spaceId, 0, "unpinned", "folder")],
			},
		],
	});
	assert.deepEqual(getRootItems(spaceId, false), [
		{ kind: "folder", id: "ready-folder" },
	]);

	(globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }).window.__lilo?.receive({
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
						id: "ready-folder",
						spaceId,
						name: "Renamed",
						color: "#333333",
						sortOrder: 0,
						isCollapsed: true,
						isPinned: true,
					},
				],
				treeItems: [treeItem("ready-folder", spaceId, 0, "pinned", "folder")],
			},
		],
	});
	assert.deepEqual(getRootItems(spaceId, true), [
		{ kind: "folder", id: "ready-folder" },
	]);

	(globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }).window.__lilo?.receive({
		event: "browserStateChanged",
		changedSpaceId: spaceId,
		activeTabId: "",
		states: [
			{
				spaceId,
				activeTabId: "",
				tabs: [],
				folders: [],
				treeItems: [],
			},
		],
	});
	assert.deepEqual(getRootItems(spaceId, true), []);
	assert.deepEqual(getRootItems(spaceId, false), []);
});

test("browserStatePatch folderUpdated patches one folder without replacing treeItems", () => {
	const spaceId = "folder-updated-space";
	const initialState = {
		tabs: [] as Parameters<typeof applySidebarTabInitialState>[0]["tabs"],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: spaceId,
		folders: [
			{
				id: "folder-1",
				spaceId,
				name: "Folder",
				color: "#111111",
				sortOrder: 0,
				isCollapsed: false,
				isPinned: false,
			},
		],
		treeItems: [treeItem("folder-1", spaceId, 0, "unpinned", "folder")],
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState(initialState as Parameters<typeof applySidebarFolderInitialState>[0]);
	initSidebarStore();

	(globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }).window.__lilo?.receive({
		event: "browserStatePatch",
		changedSpaceId: spaceId,
		activeTabId: "",
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "",
				upsertFolders: [
					{
						id: "folder-1",
						spaceId,
						name: "Renamed",
						color: "#222222",
						sortOrder: 0,
						isCollapsed: true,
						isPinned: false,
					},
				],
			},
		],
	});

	assert.deepEqual(getFolders(spaceId).map((folder) => [folder.id, folder.name, folder.isCollapsed]), [
		["folder-1", "Renamed", true],
	]);
	assert.deepEqual(getRootItems(spaceId, false), [{ kind: "folder", id: "folder-1" }]);
});

test("getRootItems uses treeItems for pinned section", () => {
	const spaceId = "pinned-root-order-space";
	const spaces = [
		{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 },
	];
	applySpaceInitialState({
		tabs: [],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		activeSpaceId: spaceId,
	});
	applySidebarTabInitialState({
		tabs: [
			makeTab({ id: "p1", spaceId, isPinned: true, isBookmarked: false, isClosed: false }),
			makeTab({ id: "p2", spaceId, isPinned: true, isBookmarked: false, isClosed: false }),
		],
		activeTabId: "p1",
		spaces,
		activeSpaceId: spaceId,
	});

	const withoutOrder = getRootItems(spaceId, true);
	assert.deepEqual(withoutOrder.map((i) => i.id), []);

	applySidebarFolderInitialState({
		tabs: [],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		activeSpaceId: spaceId,
		folders: [],
		treeItems: [
			treeItem("p1", spaceId, 0, "pinned"),
			treeItem("p2", spaceId, 1, "pinned"),
		],
	});
	const withOrder = getRootItems(spaceId, true);
	assert.deepEqual(withOrder.map((i) => i.id), ["p1", "p2"]);
});

test("applySidebarFolderInitialState hydrates treeItems from Swift initial payload", () => {
	const spaceId = "initial-root-order-space";
	const spaces = [
		{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 },
	];
	const initialState = {
		tabs: [
			makeTab({ id: "t1", spaceId, isPinned: false, isBookmarked: false, isClosed: false }),
			makeTab({ id: "t2", spaceId, isPinned: false, isBookmarked: false, isClosed: false }),
			makeTab({ id: "p1", spaceId, isPinned: true, isBookmarked: false, isClosed: false }),
			makeTab({ id: "p2", spaceId, isPinned: true, isBookmarked: false, isClosed: false }),
		],
		activeTabId: "t1",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		activeSpaceId: spaceId,
		folders: [],
		treeItems: [
			treeItem("t2", spaceId, 0),
			treeItem("t1", spaceId, 1),
			treeItem("p2", spaceId, 0, "pinned"),
			treeItem("p1", spaceId, 1, "pinned"),
		],
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState(initialState);

	assert.deepEqual(getRootItems(spaceId, false).map((i) => i.id), ["t2", "t1"]);
	assert.deepEqual(getRootItems(spaceId, true).map((i) => i.id), ["p2", "p1"]);
});

test("applySidebarFolderInitialState clears stale treeItems", () => {
	const spaceId = "root-order-reset-space";
	const spaces = [
		{ id: spaceId, name: "S", icon: "square", color: "#000", profileId: "p1", isPrivate: false, sortOrder: 0 },
	];

	applySpaceInitialState({
		tabs: [],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		activeSpaceId: spaceId,
	});
	applySidebarTabInitialState({
		tabs: [
			makeTab({ id: "t1", spaceId, isPinned: false, isBookmarked: false, isClosed: false }),
			makeTab({ id: "t2", spaceId, isPinned: false, isBookmarked: false, isClosed: false }),
		],
		activeTabId: "t1",
		spaces,
		activeSpaceId: spaceId,
	});
	applySidebarFolderInitialState({
		tabs: [],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		activeSpaceId: spaceId,
		folders: [],
		treeItems: [
			treeItem("t2", spaceId, 0),
			treeItem("t1", spaceId, 1),
		],
	});
	assert.deepEqual(getRootItems(spaceId, false).map((i) => i.id), ["t2", "t1"]);

	applySidebarFolderInitialState({
		tabs: [],
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		activeSpaceId: spaceId,
		folders: [],
		treeItems: [],
	});

	assert.deepEqual(getRootItems(spaceId, false).map((i) => i.id), []);
});
