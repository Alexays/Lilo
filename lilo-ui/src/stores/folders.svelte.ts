import type {
	BridgeTabFolderSnapshot,
	BridgeTabSnapshot,
} from "../lib/bridge/protocol";
import { getActiveSpaceId } from "./spaces.svelte";
import {
	getPendingTabDrop,
	getPreviewTabMoveToSpace,
} from "./dropConfirmation.svelte";
import { getSpaceSidebar } from "./sidebar.svelte";
import type { RootItem } from "./sidebarView";

// Façade over the unified sidebar store (stores/sidebar.svelte.ts). Getters read the
// per-write precomputed view instead of re-joining tabs × folders × treeItems on every
// render; the drag-context exclusion stays read-time (it depends on transient drop state).

export type FolderState = BridgeTabFolderSnapshot;
export type TabState = BridgeTabSnapshot;

function resolveSpaceId(spaceId?: string): string {
	return spaceId || getActiveSpaceId() || "";
}

/** The tab a transient drop/preview removes from this space's rendering, if any. */
export function dragExcludedTabId(spaceId: string): string | null {
	const pending = getPendingTabDrop();
	if (pending?.kind === "move-space" && pending.targetSpaceId !== spaceId) {
		return pending.tabId;
	}
	const preview = getPreviewTabMoveToSpace();
	if (preview && preview.targetSpaceId !== spaceId) {
		return preview.tabId;
	}
	return null;
}

export function getFolders(spaceId: string): FolderState[] {
	return getSpaceSidebar(spaceId).folders;
}

/** Precomputed per store write: reuse instead of re-deriving a Map in components. */
export function getFoldersById(spaceId?: string): Map<string, FolderState> {
	return getSpaceSidebar(resolveSpaceId(spaceId)).view.foldersById;
}

/** Each folder a lock hides, mapped to the locked folder hiding it: itself or an ancestor. */
export function getLockedFolderRoots(spaceId?: string): Map<string, string> {
	const state = getSpaceSidebar(resolveSpaceId(spaceId));
	const roots = new Map<string, string>();
	const visit = (folderId: string, rootId: string): void => {
		roots.set(folderId, rootId);
		for (const child of state.view.treeIndex.childrenByFolderId.get(folderId) ?? []) {
			if (child.kind === "folder") visit(child.itemId, rootId);
		}
	};
	for (const folder of state.folders) {
		if (folder.isLocked) visit(folder.id, roots.get(folder.id) ?? folder.id);
	}
	return roots;
}

/** `getVisibleFolderChildren(...).length` without building the arrays: called per folder on every tab patch. */
export function countVisibleFolderChildren(
	folderId: string,
	spaceId: string | undefined,
	pinned: boolean | undefined,
	tabsById: Map<string, TabState>,
): number {
	const { view } = getSpaceSidebar(resolveSpaceId(spaceId));
	let count = 0;
	for (const item of view.treeIndex.childrenByFolderId.get(folderId) ?? []) {
		if (pinned != null && item.section !== (pinned ? "pinned" : "unpinned")) continue;
		if (item.kind === "folder") {
			if (view.foldersById.has(item.itemId)) count++;
			continue;
		}
		const tab = tabsById.get(item.itemId);
		if (tab && !tab.isBookmarked && (!tab.isClosed || (pinned === true && tab.isPinned))) count++;
	}
	return count;
}

/** The rows a folder shows, its subfolders and tabs in their order. */
export function getVisibleFolderChildren(
	folderId: string,
	spaceId?: string,
	pinned?: boolean,
	tabsById?: Map<string, TabState>,
): RootItem[] {
	const resolvedSpaceId = resolveSpaceId(spaceId);
	const { view } = getSpaceSidebar(resolvedSpaceId);
	const excludedTabId = tabsById ? null : dragExcludedTabId(resolvedSpaceId);
	const tabsByIdResolved = tabsById ?? view.tabsById;
	const children: RootItem[] = [];
	for (const item of view.treeIndex.childrenByFolderId.get(folderId) ?? []) {
		if (pinned != null && item.section !== (pinned ? "pinned" : "unpinned")) continue;
		if (item.kind === "folder") {
			if (view.foldersById.has(item.itemId)) children.push({ kind: "folder", id: item.itemId });
			continue;
		}
		if (item.itemId === excludedTabId) continue;
		const tab = tabsByIdResolved.get(item.itemId);
		if (tab && !tab.isBookmarked && (!tab.isClosed || (pinned === true && tab.isPinned))) {
			children.push({ kind: "tab", id: tab.id });
		}
	}
	return children;
}

/** Folders nest at most this deep, a root folder being at depth 1, as the host enforces. */
const MAX_FOLDER_DEPTH = 5;

/** Whether `folderId` may move into `targetFolderId`: never into itself or its own subtree, never
 * a split view, and never past MAX_FOLDER_DEPTH with its subfolders. */
export function canNestFolder(folderId: string, targetFolderId: string, spaceId?: string): boolean {
	const { view } = getSpaceSidebar(resolveSpaceId(spaceId));
	if (view.foldersById.get(folderId)?.isSplit) return false;
	let depth = 0;
	for (let id: string | undefined = targetFolderId; id; id = view.treeIndex.parentFolderIdById.get(id)) {
		if (id === folderId) return false;
		depth++;
	}
	const height = (id: string): number => {
		let deepest = 0;
		for (const child of view.treeIndex.childrenByFolderId.get(id) ?? []) {
			if (child.kind === "folder") deepest = Math.max(deepest, height(child.itemId));
		}
		return deepest + 1;
	};
	return depth + height(folderId) <= MAX_FOLDER_DEPTH;
}

export function getRootItems(spaceId?: string, pinned = false): RootItem[] {
	const resolvedSpaceId = resolveSpaceId(spaceId);
	const state = getSpaceSidebar(resolvedSpaceId);

	const roots = state.view.rootItems[pinned ? "pinned" : "unpinned"];
	const excludedTabId = dragExcludedTabId(resolvedSpaceId);
	return excludedTabId
		? roots.filter((item) => !(item.kind === "tab" && item.id === excludedTabId))
		: roots;
}
