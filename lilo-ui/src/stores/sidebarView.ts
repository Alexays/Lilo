import type {
	BridgeSidebarTreeItemSnapshot,
	BridgeSidebarTreeSection,
	BridgeTabFolderSnapshot,
	BridgeTabSnapshot,
} from "../lib/bridge/protocol";

// Pure sidebar-view computation (no runes): the render hierarchy derived from
// (tabs, folders, treeItems), built once per store write instead of per render.

export type RootItem =
	| { kind: "tab"; id: string }
	| { kind: "folder"; id: string };

export type SpaceTreeIndex = {
	rootItemsBySection: Record<
		BridgeSidebarTreeSection,
		BridgeSidebarTreeItemSnapshot[]
	>;
	childrenByFolderId: Map<string, BridgeSidebarTreeItemSnapshot[]>;
	/** Only items inside a folder have an entry. */
	parentFolderIdById: Map<string, string>;
};

const emptyTreeIndex = (): SpaceTreeIndex => ({
	rootItemsBySection: {
		bookmarked: [],
		pinned: [],
		unpinned: [],
	},
	childrenByFolderId: new Map(),
	parentFolderIdById: new Map(),
});

function createSpaceTreeIndex(
	treeItems: BridgeSidebarTreeItemSnapshot[],
): SpaceTreeIndex {
	const index = emptyTreeIndex();
	const sortedItems = [...treeItems].sort((a, b) => a.sortOrder - b.sortOrder);
	for (const item of sortedItems) {
		if (item.parentFolderId == null) {
			index.rootItemsBySection[item.section].push(item);
			continue;
		}
		const existing = index.childrenByFolderId.get(item.parentFolderId) ?? [];
		existing.push(item);
		index.childrenByFolderId.set(item.parentFolderId, existing);
		index.parentFolderIdById.set(item.itemId, item.parentFolderId);
	}
	return index;
}

export interface SidebarView {
	treeIndex: SpaceTreeIndex;
	tabsById: Map<string, BridgeTabSnapshot>;
	foldersById: Map<string, BridgeTabFolderSnapshot>;
	rootItems: { pinned: RootItem[]; unpinned: RootItem[] };
	bookmarked: BridgeTabSnapshot[];
}

/** Visibility rule for a tab at the root of a pinned/unpinned section. */
function isRootVisibleTab(tab: BridgeTabSnapshot, pinned: boolean): boolean {
	return (
		tab.isPinned === pinned &&
		!tab.isBookmarked &&
		(!tab.isClosed || (pinned && tab.isPinned))
	);
}

function filterRootItems(
	sectionItems: BridgeSidebarTreeItemSnapshot[],
	tabs: BridgeTabSnapshot[],
	folderIds: Set<string>,
	pinned: boolean,
): RootItem[] {
	const tabIds = new Set(
		tabs.filter((tab) => isRootVisibleTab(tab, pinned)).map((tab) => tab.id),
	);
	return sectionItems
		.filter(
			(item) =>
				(item.kind === "tab" && tabIds.has(item.itemId)) ||
				(item.kind === "folder" && folderIds.has(item.itemId)),
		)
		.map((item) => ({ kind: item.kind, id: item.itemId }));
}

export function computeSidebarView(
	tabs: BridgeTabSnapshot[],
	folders: BridgeTabFolderSnapshot[],
	treeItems: BridgeSidebarTreeItemSnapshot[],
): SidebarView {
	const treeIndex = createSpaceTreeIndex(treeItems);
	const folderIds = new Set(folders.map((folder) => folder.id));
	const tabsById = new Map(tabs.map((tab) => [tab.id, tab]));
	return {
		treeIndex,
		tabsById,
		foldersById: new Map(folders.map((folder) => [folder.id, folder])),
		rootItems: {
			pinned: filterRootItems(
				treeIndex.rootItemsBySection.pinned,
				tabs,
				folderIds,
				true,
			),
			unpinned: filterRootItems(
				treeIndex.rootItemsBySection.unpinned,
				tabs,
				folderIds,
				false,
			),
		},
		bookmarked: treeIndex.rootItemsBySection.bookmarked
			.map((item) => tabsById.get(item.itemId))
			.filter((tab): tab is BridgeTabSnapshot => tab != null && tab.isBookmarked),
	};
}

/** Cheap view refresh when only tabs' runtime snapshots changed (no membership/flag change). */
export function viewWithUpdatedTabs(
	view: SidebarView,
	updated: ReadonlyMap<string, BridgeTabSnapshot>,
): SidebarView {
	const tabsById = new Map(view.tabsById);
	for (const tab of updated.values()) tabsById.set(tab.id, tab);
	return {
		...view,
		tabsById,
		bookmarked: view.bookmarked.some((entry) => updated.has(entry.id))
			? view.bookmarked.map((entry) => updated.get(entry.id) ?? entry)
			: view.bookmarked,
	};
}
