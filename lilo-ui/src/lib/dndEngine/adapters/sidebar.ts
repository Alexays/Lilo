import {
	DND_SHADOW_ITEM_ID_PREFIX,
	insertShadowItem,
	isShadowItem,
	removeShadowItems,
} from "../projection";
import { MOTION } from "../../motion/timings";
import type {
	BridgeSidebarDropPayload,
	BridgeSidebarItemKind,
	BridgeSidebarTreeSection,
} from "../../bridge/protocol";
import type { DndItem } from "../types";

export type SidebarDndItem = {
	id: string;
	kind: BridgeSidebarItemKind;
	section: BridgeSidebarTreeSection;
	parentFolderId: string | null;
};

type RootItem = {
	id: string;
	kind: BridgeSidebarItemKind;
};

type TabLike = {
	id: string;
};

export function dndItemsForSidebarItems(
	items: RootItem[],
	section: Exclude<BridgeSidebarTreeSection, "bookmarked">,
	parentFolderId: string | null = null,
): SidebarDndItem[] {
	return items.map((item) => ({
		id: item.id,
		kind: item.kind,
		section,
		parentFolderId,
	}));
}

export function dndItemsForFolderTabs(
	tabs: TabLike[],
	section: BridgeSidebarTreeSection = "bookmarked",
	parentFolderId: string | null = null,
): SidebarDndItem[] {
	return tabs.map((tab) => ({
		id: tab.id,
		kind: "tab",
		section,
		parentFolderId,
	}));
}

export function sidebarDndKey(item: SidebarDndItem): string {
	return `${item.id}:${isShadowItem(item) ? "shadow" : "item"}`;
}

// A FLIP pass measures and animates every row in the list (O(n) getBoundingClientRect +
// transforms), so past this count the list snaps instead of animating.
const FLIP_MAX_ANIMATED_ITEMS = 60;

export function flipDurationForSidebarDndItem(
	item: Pick<SidebarDndItem, "id">,
	options: { recentlyDraggedId?: string | null; itemCount: number },
): number {
	if (options.itemCount > FLIP_MAX_ANIMATED_ITEMS) return 0;
	if (options.recentlyDraggedId === item.id) return 0;
	return MOTION.reorderMs;
}

export function materializeSidebarProjection(
	items: readonly SidebarDndItem[],
	draggedId: string,
): SidebarDndItem[] {
	const shadowId = `${DND_SHADOW_ITEM_ID_PREFIX}${draggedId}`;
	let materializedIndex = -1;
	const materialized = items.map((item, index) => {
		if (item.id !== shadowId) return item;
		materializedIndex = index;
		return {
			...item,
			id: draggedId,
		};
	});

	if (materializedIndex < 0) return materialized;
	return materialized.filter((item, index) => item.id !== draggedId || index === materializedIndex);
}

export function projectSidebarItemsWithShadow(
	items: readonly SidebarDndItem[],
	draggedId: string,
	targetIndex: number,
	target: {
		section: BridgeSidebarTreeSection;
		parentFolderId: string | null;
	},
	sourceItem?: Pick<DndItem, "id" | "kind">,
): SidebarDndItem[] {
	const dragged = removeShadowItems(items).find((item) => item.id === draggedId) ?? {
		id: draggedId,
		kind: sourceItem?.kind === "folder" ? "folder" : "tab",
		section: target.section,
		parentFolderId: target.parentFolderId,
	};
	if (dragged.kind === "folder" && target.section === "bookmarked") return [...items];
	const withoutDragged = removeShadowItems(items).filter((item) => item.id !== draggedId);
	return insertShadowItem(withoutDragged, {
		...dragged,
		section: target.section,
		parentFolderId: target.parentFolderId,
	}, targetIndex);
}

export function commitFromDndProjection({
	draggedId,
	items,
	section,
	parentFolderId,
}: {
	draggedId: string;
	items: SidebarDndItem[];
	section: BridgeSidebarTreeSection;
	parentFolderId: string | null;
}): BridgeSidebarDropPayload | null {
	const indexInItems = items.findIndex((item) =>
		item.id === `${DND_SHADOW_ITEM_ID_PREFIX}${draggedId}`
	);
	if (indexInItems < 0) return null;

	const shadowItem = items[indexInItems];
	const kind = shadowItem.kind;
	const fallbackIndex = items
		.slice(0, indexInItems)
		.filter((item) => !isShadowItem(item) && item.id !== draggedId).length;
	const insertAfterId = items
		.slice(0, indexInItems)
		.findLast((item) => !isShadowItem(item) && item.id !== draggedId)
		?.id ?? null;
	const insertBeforeId = items
		.slice(indexInItems + 1)
		.find((item) => !isShadowItem(item) && item.id !== draggedId)
		?.id ?? null;

	const anchors = { fallbackIndex, insertBeforeId, insertAfterId };
	if (section === "bookmarked") {
		if (kind !== "tab") return null;
		return { type: "insert", kind, id: draggedId, section, parentFolderId: null, ...anchors };
	}
	if (parentFolderId) {
		return { type: "insert", kind, id: draggedId, section, parentFolderId, ...anchors };
	}
	return { type: "insert", kind, id: draggedId, section, parentFolderId: null, ...anchors };
}

export type SidebarZoneRef = {
	id: string;
	section: BridgeSidebarTreeSection;
	parentFolderId: string | null;
};

export type SidebarPlaceholder = {
	zone: SidebarZoneRef;
	index: number;
};

export type SidebarDragSnapshot = {
	itemId: string;
	kind: BridgeSidebarItemKind;
	source: SidebarZoneRef;
	target: SidebarZoneRef | null;
	targetIndex: number;
	// Where the drop placeholder renders: the target, except over a collapsed folder, where
	// it stays where it was (hidden) so the rows do not slide out from under the pointer.
	placeholder: SidebarPlaceholder | null;
	intoCollapsedFolder: boolean;
};

// The single source of truth for what a sidebar zone renders mid-drag. Every zone
// derives its rows from this, so entering one zone implicitly leaves the others:
// there is no cross-zone bookkeeping to keep in sync.
export function projectZoneItems(
	baseItems: readonly SidebarDndItem[],
	zone: SidebarZoneRef,
	drag: SidebarDragSnapshot | null,
): SidebarDndItem[] {
	// The base array itself, not a copy: callers memoize it, and a new identity would re-run
	// every animated list reading it.
	if (!drag) return baseItems as SidebarDndItem[];

	if (drag.placeholder?.zone.id === zone.id) {
		return projectSidebarItemsWithShadow(
			baseItems,
			drag.itemId,
			drag.placeholder.index,
			{ section: zone.section, parentFolderId: zone.parentFolderId },
			{ id: drag.itemId, kind: drag.kind },
		);
	}

	// No placeholder here: the dragged row is lifted out. A zone that never held it keeps its
	// base array, so a target change does not re-run every other zone's list.
	if (!baseItems.some((item) => item.id === drag.itemId || isShadowItem(item))) {
		return baseItems as SidebarDndItem[];
	}
	return removeShadowItems(baseItems).filter((item) => item.id !== drag.itemId);
}
